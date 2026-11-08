import AppKit
import Foundation
import QuartzCore

/// Produces low-frequency authoritative samples from Music.app. Visual
/// progress is interpolated by the renderers between these samples.
final class PlaybackMonitor {
    enum Update {
        case track(TrackInfo)
        case stopped
        case musicNotRunning
        case failure(Error)
    }

    struct CommandExpectation {
        let state: PlayerState
        let trackKey: String?

        // nil means keep waiting on the normal playback sampling loop.
        func resolution(for update: Update) -> Bool? {
            switch update {
            case .track(let track):
                if let trackKey, track.identityKey != trackKey { return false }
                return track.state == state ? true : nil
            case .musicNotRunning: return false
            case .stopped, .failure: return nil
            }
        }
    }

    private struct PendingCommand {
        let id = UUID()
        let expectation: CommandExpectation
        let continuation: CheckedContinuation<Bool, Never>
        var samplingStarted = false
    }

    private static let playingInterval: TimeInterval = 0.25
    private static let idleInterval: TimeInterval = 1
    private static let musicClosedInterval: TimeInterval = 2
    private static let helperName = "AppleMusicLyricsPlaybackHelper"
    private static let musicBundleIdentifier = "com.apple.Music"

    private struct HelperResponse: Decodable {
        let kind: String
        let title: String?
        let artist: String?
        let album: String?
        let duration: TimeInterval?
        let position: TimeInterval?
        let state: String?
        let error: String?
        let bpm: Int?
    }

    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var helperProcess: Process?
    private var helperInput: Pipe?
    private var helperOutput: Pipe?
    private var responseBuffer = Data()
    private var requestStartedAt: CFTimeInterval?
    private var pendingCommand: PendingCommand?
    private var commandTimeout: DispatchWorkItem?
    private var isStopping = false

    var onUpdate: ((Update) -> Void)?

    func start() {
        guard timer == nil else { return }
        isStopping = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.musicBundleIdentifier else { return }
                self?.sampleNow()
            }
        }
        scheduleSamples(every: Self.playingInterval)
        sampleNow()
    }

    private func scheduleSamples(every interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        timer.tolerance = interval * 0.16
        self.timer = timer

        // Menu tracking switches the main run loop out of its default mode.
        // Sampling through the helper is asynchronous, so keep it active while
        // the status menu is open to update its playback controls and lyrics.
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        isStopping = true
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        stopHelper()
        cancelCommandConfirmation()
    }

    @MainActor
    func confirmCommand(_ expectation: CommandExpectation) async -> Bool {
        guard !isStopping, !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            cancelCommandConfirmation()
            let command = PendingCommand(expectation: expectation, continuation: continuation)
            pendingCommand = command
            let timeout = DispatchWorkItem { [weak self] in
                guard self?.pendingCommand?.id == command.id else { return }
                self?.cancelCommandConfirmation()
            }
            commandTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
            sampleNow()
        }
    }

    func cancelCommandConfirmation() { finishCommandConfirmation(false) }

    private func finishCommandConfirmation(_ confirmed: Bool) {
        commandTimeout?.cancel()
        commandTimeout = nil
        let command = pendingCommand
        pendingCommand = nil
        command?.continuation.resume(returning: confirmed)
    }

    func sampleNow() {
        guard !isStopping else { return }
        if let requestStartedAt {
            guard CACurrentMediaTime() - requestStartedAt > 2 else { return }
            stopHelper()
        }
        startHelperIfNeeded()
        guard let input = helperInput?.fileHandleForWriting else {
            cancelCommandConfirmation()
            return
        }
        pendingCommand?.samplingStarted = true
        requestStartedAt = CACurrentMediaTime()
        input.write(Data("sample\n".utf8))
    }

    private func startHelperIfNeeded() {
        guard helperProcess == nil, let helperURL = Self.helperExecutableURL else { return }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.helperOutput?.fileHandleForReading === handle else { return }
                self.consume(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, !self.isStopping, self.helperProcess === process else { return }
                self.stopHelper()
                self.cancelCommandConfirmation()
            }
        }

        do {
            try process.run()
            helperProcess = process
            helperInput = input
            helperOutput = output
        } catch {
            onUpdate?(.failure(error))
        }
    }

    private func stopHelper() {
        helperOutput?.fileHandleForReading.readabilityHandler = nil
        try? helperInput?.fileHandleForWriting.close()
        try? helperOutput?.fileHandleForReading.close()
        if helperProcess?.isRunning == true {
            helperProcess?.terminate()
        }
        helperProcess = nil
        helperInput = nil
        helperOutput = nil
        responseBuffer.removeAll(keepingCapacity: true)
        requestStartedAt = nil
    }

    private func consume(_ data: Data) {
        responseBuffer.append(data)
        while let newline = responseBuffer.firstIndex(of: 0x0A) {
            let line = responseBuffer[..<newline]
            responseBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let response = try? JSONDecoder().decode(HelperResponse.self, from: line) else {
                continue
            }
            requestStartedAt = nil
            let command = pendingCommand
            guard let update = update(from: response) else { continue }
            onUpdate?(update)
            if let command, command.samplingStarted, pendingCommand?.id == command.id,
               let confirmed = command.expectation.resolution(for: update) {
                finishCommandConfirmation(confirmed)
            }
        }
        if pendingCommand?.samplingStarted == false, requestStartedAt == nil {
            sampleNow()
        }
    }

    private func update(from response: HelperResponse) -> Update? {
        switch response.kind {
        case "track":
            guard let title = response.title,
                  let artist = response.artist,
                  let album = response.album,
                  let duration = response.duration,
                  let position = response.position,
                  let state = response.state else { return nil }
            let playerState = PlayerState(appleScriptValue: state)
            scheduleSamples(every: playerState == .playing ? Self.playingInterval : Self.idleInterval)
            return .track(TrackInfo(title: title, artist: artist, album: album, duration: duration,
                                    position: position, state: playerState, bpm: response.bpm))
        case "stopped":
            scheduleSamples(every: Self.idleInterval)
            return .stopped
        case "musicNotRunning":
            // Keep the current lyrics if the helper briefly loses sight of a live Music process.
            let music = NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier)
            guard music.allSatisfy(\.isTerminated) else { return nil }
            scheduleSamples(every: Self.musicClosedInterval)
            return .musicNotRunning
        default:
            scheduleSamples(every: Self.idleInterval)
            return .failure(PlaybackMonitorError.helper(response.error ?? "Unknown helper error"))
        }
    }

    static var helperExecutableURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Self.helperName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent(Self.helperName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}

private enum PlaybackMonitorError: LocalizedError {
    case helper(String)

    var errorDescription: String? {
        guard case .helper(let message) = self else { return nil }
        return message
    }
}
