import AppKit

@MainActor
final class ArtworkService {
    var onChange: ((NSImage?) -> Void)?
    private var trackKey: String?
    private var requestedURL: URL?
    private var generation = 0
    private var task: Task<Void, Never>?
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 32 }

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
        if changed { onChange?(nil) }
        if let url, let image = cache.object(forKey: url as NSURL) { onChange?(image); return }
        task = Task { [weak self] in
            var image: NSImage?
            if let url {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 8
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    image = NSImage(data: data)
                }
            }
            if image == nil && !Task.isCancelled {
                let data = await Task.detached(priority: .utility) { Self.musicArtwork(for: track) }.value
                image = data.flatMap(NSImage.init(data:))
            }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            if let image, let url { self.cache.setObject(image, forKey: url as NSURL) }
            self.onChange?(image)
        }
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
