import Foundation
import os

/// Apple-only lyrics service backed by Music.app's local URL cache.
final class LyricsService: Sendable {
    private let provider: AppleMusicCacheLyricsProvider
    private let cacheQueue = DispatchQueue(label: "music.lyrics-cache", qos: .userInitiated)

    init(provider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()) {
        self.provider = provider
    }

    func lyrics(for track: TrackInfo) async -> LyricsDocument {
        // SQLite and filesystem calls block, so keep them off Swift's cooperative executor.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cacheQueue.async { [provider] in
                    let lyrics = provider.lyrics(for: track, isCancelled: { cancelled.withLock { $0 } })
                    continuation.resume(returning: lyrics)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
