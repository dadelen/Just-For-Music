import Foundation
import os

/// Apple-only lyrics service backed by Music.app's local URL cache.
final class LyricsService: Sendable {
    private struct CacheEntry: Sendable {
        let key: String
        let document: LyricsDocument
    }

    private static let maximumCachedTracks = 12
    private let provider: AppleMusicCacheLyricsProvider
    private let cacheQueue = DispatchQueue(label: "music.lyrics-cache", qos: .userInitiated)
    private let recentLyrics = OSAllocatedUnfairLock(initialState: [CacheEntry]())

    init(provider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()) {
        self.provider = provider
    }

    func lyrics(for track: TrackInfo, bypassMemory: Bool = false,
                recentIndexOnly: Bool = false) async -> LyricsDocument {
        // SQLite and filesystem calls block, so keep them off Swift's cooperative executor.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cacheQueue.async {
                    let lyrics = self.load(for: track, bypassMemory: bypassMemory, recentIndexOnly: recentIndexOnly,
                                           isCancelled: { cancelled.withLock { $0 } })
                    continuation.resume(returning: lyrics)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private func load(for track: TrackInfo, bypassMemory: Bool, recentIndexOnly: Bool,
                      isCancelled: () -> Bool) -> LyricsDocument {
        guard !isCancelled() else { return .empty }
        let key = track.identityKey
        let cached = recentLyrics.withLock { entries -> LyricsDocument? in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            if bypassMemory { return nil }
            entries.append(entry)
            return entry.document
        }
        if let cached {
            DiagnosticLogger.shared.info("Lyrics memory cache hit; track=\(track.displayName)")
            return cached
        }

        let document = provider.lyrics(for: track, recentIndexOnly: recentIndexOnly,
                                       bypassDirectoryCooldown: bypassMemory, isCancelled: isCancelled)
        guard !isCancelled(), !document.lines.isEmpty else { return .empty }
        recentLyrics.withLock { entries in
            entries.append(CacheEntry(key: key, document: document))
            if entries.count > Self.maximumCachedTracks { entries.removeFirst() }
        }
        return document
    }
}
