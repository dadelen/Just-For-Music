import AppKit
import CoreServices
import Darwin
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
        let trackKey: String

        // nil means keep waiting on the normal playback sampling loop.
        func resolution(for update: Update) -> Bool? {
            switch update {
            case .track(let track):
                if track.identityKey != trackKey { return false }
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

    private struct ControlRequest {
        let arguments: [String]
        let completion: (Bool) -> Void
    }

    private static let playingInterval: TimeInterval = 1.25
    private static let idleInterval: TimeInterval = 3.0
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
        let controlErrors: [String?]?
    }

    private let helperURL: URL?
    private let isMusicRunning: () -> Bool
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var musicObserver: NSObjectProtocol?
    private var eventSample: DispatchWorkItem?
    private var needsEventSample = false
    private var helperProcess: Process?
    private var helperInput: Pipe?
    private var helperOutput: Pipe?
    private var responseBuffer = Data()
    private var requestStartedAt: CFTimeInterval?
    private var queuedControls: [ControlRequest] = []
    private var activeControls: [ControlRequest] = []
    private var pendingCommand: PendingCommand?
    private var commandTimeout: DispatchWorkItem?
    private var isStopping = false
    private var screensAwake = true

    var onUpdate: ((Update) -> Void)?

    init(helperURL: URL? = PlaybackMonitor.helperExecutableURL, isMusicRunning: (() -> Bool)? = nil) {
        self.helperURL = helperURL
        self.isMusicRunning = isMusicRunning ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier)
                .contains { !$0.isTerminated }
        }
    }

    func start() {
        guard musicObserver == nil else { return }
        isStopping = false
        screensAwake = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.musicBundleIdentifier else { return }
                self?.sampleNow()
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.setScreensAwake(notification.name == NSWorkspace.screensDidWakeNotification)
            })
        }
        // Music's notification is a hint. Always confirm it with the helper.
        musicObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleEventSample()
        }
        scheduleSamples(every: Self.playingInterval)
        sampleNow()
    }

    private func scheduleSamples(every interval: TimeInterval?) {
        let interval = screensAwake || pendingCommand != nil ? interval : nil
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
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

    private func setScreensAwake(_ awake: Bool) {
        screensAwake = awake
        if awake {
            scheduleEventSample()
        } else if pendingCommand == nil {
            eventSample?.cancel()
            eventSample = nil
            needsEventSample = false
            scheduleSamples(every: nil)
        }
    }

    func stop() {
        isStopping = true
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let musicObserver { DistributedNotificationCenter.default().removeObserver(musicObserver) }
        musicObserver = nil
        eventSample?.cancel()
        eventSample = nil
        needsEventSample = false
        stopHelper()
        cancelCommandConfirmation()
    }

    private func scheduleEventSample() {
        guard (screensAwake || pendingCommand != nil), eventSample == nil else { return }
        let sample = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventSample = nil
            self.needsEventSample = true
            self.sampleNow()
        }
        eventSample = sample
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: sample)
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
        if !screensAwake { scheduleSamples(every: nil) }
        command?.continuation.resume(returning: confirmed)
    }

    func sampleNow() {
        guard !isStopping, screensAwake || pendingCommand != nil || !queuedControls.isEmpty else { return }
        // After Music quits, a launch, wake or control request restarts sampling
        // and gives the helper a retry even if its first reply never arrives.
        if musicObserver != nil, timer == nil { scheduleSamples(every: Self.idleInterval) }
        if let requestStartedAt {
            let timeout: TimeInterval = activeControls.isEmpty ? 2 : 5
            guard CACurrentMediaTime() - requestStartedAt > timeout else { return }
            stopHelper()
            cancelCommandConfirmation()
        }
        startHelperIfNeeded()
        guard let input = helperInput?.fileHandleForWriting else {
            failControls()
            cancelCommandConfirmation()
            return
        }
        // Bound each pipe write. Rapid clicks retain their order and share one state sample.
        activeControls = Array(queuedControls.prefix(16))
        queuedControls.removeFirst(activeControls.count)
        let request: String
        if activeControls.isEmpty {
            pendingCommand?.samplingStarted = true
            request = "sample"
        } else {
            request = activeControls.map { $0.arguments.joined(separator: " ") }.joined(separator: "\t")
        }
        requestStartedAt = CACurrentMediaTime()
        needsEventSample = false
        do {
            try input.write(contentsOf: Data((request + "\n").utf8))
        } catch {
            stopHelper()
            cancelCommandConfirmation()
        }
    }

    func performControl(_ arguments: [String], completion: @escaping (Bool) -> Void) {
        guard !isStopping else { completion(false); return }
        queuedControls.append(ControlRequest(arguments: arguments, completion: completion))
        sampleNow()
    }

    private func startHelperIfNeeded() {
        guard helperProcess == nil, let helperURL else { return }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        // Music or the helper can exit between the liveness check and a write.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return }
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
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
            output.fileHandleForReading.readabilityHandler = nil
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
        failControls()
    }

    private func failControls() {
        let controls = activeControls + queuedControls
        activeControls.removeAll()
        queuedControls.removeAll()
        for control in controls { control.completion(false) }
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
            let controls = activeControls
            activeControls.removeAll(keepingCapacity: true)
            // Finish controls first so seek handlers can reset the lyric clock before the new sample.
            for (index, control) in controls.enumerated() {
                if let errors = response.controlErrors, errors.count == controls.count {
                    if let error = errors[index] {
                        DiagnosticLogger.shared.warning("Playback control \(control.arguments[0]) failed: \(error)")
                    }
                    control.completion(errors[index] == nil)
                } else {
                    control.completion(false)
                }
            }
            let command = pendingCommand
            guard let update = update(from: response) else { continue }
            onUpdate?(update)
            if let command, command.samplingStarted, pendingCommand?.id == command.id,
               let confirmed = command.expectation.resolution(for: update) {
                finishCommandConfirmation(confirmed)
            }
        }
        if !queuedControls.isEmpty || needsEventSample || pendingCommand?.samplingStarted == false {
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
            guard !isMusicRunning() else { return nil }
            // A control completion may already have started another request.
            if requestStartedAt == nil { scheduleSamples(every: nil) }
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

    static func hasMusicAutomationAccess() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleIdentifier)
        guard let address = target.aeDesc else { return false }
        return withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
        }
    }
}

private enum PlaybackMonitorError: LocalizedError {
    case helper(String)

    var errorDescription: String? {
        guard case .helper(let message) = self else { return nil }
        return message
    }
}
