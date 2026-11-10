import AppKit
import ImageIO

@MainActor
final class ArtworkService {
    var onChange: ((NSImage?) -> Void)?
    private var trackKey: String?
    private var requestedURL: URL?
    private var generation = 0
    private var task: Task<Void, Never>?
    private let cache = NSCache<NSString, NSImage>()
    private let cachedURLByTrack = NSCache<NSString, NSString>()

    init() {
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1024 * 1024
        cachedURLByTrack.countLimit = 32
    }

    func update(track: TrackInfo?, url: URL?) {
        guard let track else {
            guard trackKey != nil else { return }
            task?.cancel()
            generation += 1
            trackKey = nil
            requestedURL = nil
            onChange?(nil)
            return
        }
        let changed = trackKey != track.identityKey
        guard changed || (url != nil && requestedURL != url) else { return }
        task?.cancel()
        generation += 1
        let request = generation
        trackKey = track.identityKey
        requestedURL = url
        let localKey = "track:\(track.identityKey)" as NSString
        let urlKey = url.map { "url:\($0.absoluteString)" as NSString }
        let rememberedKey = cachedURLByTrack.object(forKey: localKey)
        let cached = urlKey.flatMap(cache.object(forKey:))
            ?? (urlKey == nil ? rememberedKey.flatMap(cache.object(forKey:)) ?? cache.object(forKey: localKey) : nil)
        if let cached {
            if let urlKey { cachedURLByTrack.setObject(urlKey, forKey: localKey) }
            onChange?(cached)
            return
        }
        if changed { onChange?(nil) }
        task = Task { [weak self] in
            var thumbnail: CGImage?
            if let url {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 8
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    thumbnail = await Task.detached(priority: .utility) { Self.thumbnail(from: data) }.value
                }
            }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            var cacheKey = urlKey ?? localKey
            if thumbnail == nil {
                cacheKey = localKey
                if let image = self.cache.object(forKey: localKey) {
                    self.onChange?(image)
                    return
                }
                thumbnail = await Task.detached(priority: .utility) {
                    Self.musicArtwork(for: track).flatMap(Self.thumbnail(from:))
                }.value
            }
            guard !Task.isCancelled, self.generation == request else { return }
            guard let thumbnail else { self.onChange?(nil); return }
            let image = NSImage(cgImage: thumbnail, size: .zero)
            self.cache.setObject(image, forKey: cacheKey, cost: thumbnail.bytesPerRow * thumbnail.height)
            if cacheKey != localKey { self.cachedURLByTrack.setObject(cacheKey, forKey: localKey) }
            self.onChange?(image)
        }
    }

    private nonisolated static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private nonisolated static func musicArtwork(for track: TrackInfo) -> Data? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
        let script = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application id "com.apple.Music"
                set t to current track
                return {name of t, artist of t, duration of t, raw data of artwork 1 of t}
            end tell
        end timeout
        """)
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil,
              result.atIndex(1)?.stringValue == track.title,
              result.atIndex(2)?.stringValue == track.artist,
              let durationDescriptor = result.atIndex(3),
              abs(durationDescriptor.doubleValue - track.duration) < 2 else { return nil }
        return result.atIndex(4)?.data
    }
}
