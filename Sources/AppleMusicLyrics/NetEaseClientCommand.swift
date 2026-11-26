import AppKit

/// NetEase Desktop accepts these playback commands through its registered
/// orpheus URL handler. Pass the URL directly to the selected, running client.
enum NetEaseClientCommand {
    case previous, next, resume, pause
    case seek(TimeInterval)

    var url: URL? {
        let name: String
        var value: Double?
        switch self {
        case .previous: name = "previous"
        case .next: name = "next"
        case .resume: name = "resume"
        case .pause: name = "pause"
        case .seek(let seconds):
            guard seconds.isFinite, seconds >= 0 else { return nil }
            name = "seek"
            value = seconds
        }
        struct Payload: Encodable { let cmd: String; let value: Double? }
        guard let payload = try? JSONEncoder().encode(Payload(cmd: name, value: value)) else { return nil }
        return URL(string: "orpheus://" + payload.base64EncodedString())
    }

    static func applicationURL(for process: NSRunningApplication) -> URL? {
        guard !process.isTerminated, process.bundleIdentifier == NetEasePlayback.bundleID,
              let url = process.bundleURL, let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version.compare("3.1.13", options: .numeric) != .orderedAscending,
              let handlers = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              handlers.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains("orpheus") == true })
        else { return nil }
        return url
    }

    /// Called on the serial player worker, never while holding the main run loop.
    func send(to applicationURL: URL, active: () -> Bool) -> Bool {
        guard let url, active() else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        let finished = DispatchSemaphore(value: 0)
        var delivered = false
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: config) { app, error in
            delivered = error == nil && app?.bundleIdentifier == NetEasePlayback.bundleID
            finished.signal()
        }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            // A tardy callback can still deliver the command. Avoid retrying it
            // through Accessibility, especially for next/previous.
            return true
        }
        return delivered
    }
}
