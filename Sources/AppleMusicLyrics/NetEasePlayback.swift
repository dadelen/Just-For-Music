import AppKit
import ApplicationServices
import CoreAudio
import Darwin
import os
import QuartzCore

/// Keep transport commands independent of local playback sampling.
final class NetEasePlayback {
    static let bundleID = "com.netease.163music"
    var onUpdate: ((PlaybackMonitor.Update) -> Void)?

    private let queue = DispatchQueue(label: "music.netease.sampling", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "music.netease.transport", qos: .userInitiated)
    private var session: Operation?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screensAwake = true
    private var sampling = false
    private var commandPollingDeadline: TimeInterval = 0
    private var sampleRevision = 0
    private var pendingSeek: Operation?
    private lazy var reader = NetEaseAXReader()
    private lazy var controller = NetEaseAXReader()

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard session == nil else { return }
        session = Operation()
        screensAwake = true
        let notifications = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let self else { return }
                self.screensAwake = event.name == NSWorkspace.screensDidWakeNotification
                self.schedule(every: self.screensAwake ? 1 : nil)
                if self.screensAwake { self.sampleNow() }
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleID else { return }
                guard let self else { return }
                self.queue.async { self.reader.invalidateCachedApp() }
                self.sampleNow()
            })
        }
        schedule(every: 1.25)
        sampleNow()
    }

    private func schedule(every interval: TimeInterval?) {
        guard let interval else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sampleNow() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        session?.cancel()
        session = nil
        pendingSeek?.cancel()
        pendingSeek = nil
        timer?.invalidate()
        timer = nil
        sampling = false
        commandPollingDeadline = 0
    }

    func sampleNow() {
        guard let session, screensAwake, !sampling else { return }
        let revision = sampleRevision
        let pollingAfterCommand = ProcessInfo.processInfo.systemUptime < commandPollingDeadline
        sampling = true
        queue.async { [weak self] in
            guard let self, !session.isCancelled else { return }
            let update = self.reader.sample(prefersLocal: pollingAfterCommand)
            DispatchQueue.main.async {
                guard self.session === session else { return }
                self.sampling = false
                guard self.screensAwake else { return }
                guard self.sampleRevision == revision else { self.sampleNow(); return }
                if ProcessInfo.processInfo.systemUptime < self.commandPollingDeadline {
                    self.schedule(every: 0.10)
                } else {
                    switch update {
                    case .track(let track): self.schedule(every: track.state == .paused ? 2.0 : 1.25)
                    case .musicNotRunning: self.schedule(every: nil)
                    case .failure, .stopped: self.schedule(every: 4)
                    }
                }
                self.onUpdate?(update)
            }
        }
    }

    func performControl(_ arguments: [String], completion: @escaping (Bool) -> Void) {
        guard let session else { return completion(false) }
        pendingSeek?.cancel()
        let request = Operation()
        pendingSeek = arguments.first == "seek" ? request : nil
        controlQueue.async { [weak self] in
            guard let self, !session.isCancelled, !request.isCancelled else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let ok = self.controller.control(arguments, active: { !session.isCancelled && !request.isCancelled })
            DispatchQueue.main.async {
                guard self.session === session else { return completion(false) }
                if self.pendingSeek === request { self.pendingSeek = nil }
                let succeeded = ok && !request.isCancelled
                if succeeded {
                    self.sampleRevision += 1
                    if arguments.first == "seek" {
                        self.queue.async { self.reader.resetClock() }
                    }
                    if self.screensAwake {
                        self.commandPollingDeadline = ProcessInfo.processInfo.systemUptime + 2.5
                        self.schedule(every: 0.10)
                    }
                }
                completion(succeeded)
                self.sampleNow()
            }
        }
    }
}

private enum NetEaseReadError: LocalizedError {
    case missingPlaybackRecord
    var errorDescription: String? {
        "等待网易云写入播放进度。请在网易云中播放或切歌。"
    }
}

enum NetEaseAudioOutput {
    private static let objectCache = OSAllocatedUnfairLock(initialState: [pid_t: AudioObjectID]())

    /// Queries CoreAudio HAL (macOS 14.2+) to check whether NetEase Music is actively
    /// outputting audio.
    static func state(for processes: [NSRunningApplication], bundleID: String = NetEasePlayback.bundleID) -> PlayerState? {
        guard #available(macOS 14.2, *) else { return nil }
        var sawProcess = false
        for process in processes {
            let pid = process.processIdentifier
            if let cached = objectCache.withLock({ $0[pid] }) {
                if let running = isRunningOutput(cached) {
                    sawProcess = true
                    if running { return .playing }
                    continue
                }
                _ = objectCache.withLock { $0.removeValue(forKey: pid) }
            }
            guard !process.isTerminated, let object = processObject(for: pid) else { continue }
            objectCache.withLock { $0[pid] = object }
            sawProcess = true
            if isRunningOutput(object) == true { return .playing }
        }
        guard let objects = allProcessObjects() else {
            return sawProcess ? .paused : nil
        }
        for object in objects {
            guard let objectBundle = bundleIdentifier(of: object),
                  objectBundle == bundleID || objectBundle.hasPrefix(bundleID + ".") else { continue }
            if isRunningOutput(object) == true { return .playing }
        }
        return .paused
    }

    @available(macOS 14.2, *)
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var targetPID = pid
        var object: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &targetPID,
            &size,
            &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    @available(macOS 14.2, *)
    private static func allProcessObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return nil
        }
        return objects
    }

    @available(macOS 14.2, *)
    private static func isRunningOutput(_ object: AudioObjectID) -> Bool? {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleIdentifier(of object: AudioObjectID) -> String? {
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged) == noErr else { return nil }
        return unmanaged?.takeRetainedValue() as String?
    }
}

private final class NetEaseAXReader {
    private struct PlayIntent {
        let state: PlayerState
        let pid: pid_t
        let trackID: String?
        let deadline: TimeInterval
    }

    private struct CachedApp {
        let pid: pid_t
        let process: NSRunningApplication
        let commandURL: URL?
    }

    private struct CachedMetadata {
        let id: String
        let song: NetEaseQueueSong?
        let history: NetEaseHistoryEntry?
        let fetchedAt: TimeInterval
    }

    private var motion = NetEaseClockObservation()
    private var clock = NetEasePlaybackClock()
    private let localPlayback = NetEaseLocalPlayback()
    private var observedPID: pid_t?
    private var playbackWindow: AXUIElement?
    private var lastReadMode: String?
    private let playingQueue = NetEasePlayingQueue()
    private let historyStore = NetEaseHistoryStore()
    private var playIntent: PlayIntent?
    private var cachedApp: CachedApp?
    private var cachedMetadata: CachedMetadata?

    init() {
        // Set the AX messaging timeout for this client process and its element handles.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    func resetClock() { clock = NetEasePlaybackClock() }
    func invalidateCachedApp() { cachedApp = nil }

    private func activeApp() -> CachedApp? {
        if let cached = cachedApp, kill(cached.pid, 0) == 0 {
            return cached
        }
        cachedApp = nil
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: NetEasePlayback.bundleID)
            .first(where: { !$0.isTerminated }) else { return nil }
        let cached = CachedApp(
            pid: process.processIdentifier,
            process: process,
            commandURL: NetEaseClientCommand.applicationURL(for: process)
        )
        cachedApp = cached
        return cached
    }

    private func runningApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: NetEasePlayback.bundleID)
            .filter { !$0.isTerminated }
    }

    // Chromium-based clients expose their full accessibility tree on demand.
    // These are client-defined AX attributes, honoured only after macOS grants access.
    private func enableRendererAccessibility(_ app: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, observedPID != pid else { return }
        observedPID = pid
        playbackWindow = nil
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
        }
    }

    func sample(prefersLocal: Bool = false) -> PlaybackMonitor.Update {
        guard let active = activeApp() else {
            motion = NetEaseClockObservation()
            resetClock()
            observedPID = nil
            playbackWindow = nil
            lastReadMode = nil
            cachedMetadata = nil
            return .musicNotRunning
        }
        let snapshot = localPlayback.read()
        let now = Date()
        // The Accessibility menu can supplement an absent playback state on older clients.
        let needsMenuCheck = snapshot == nil || (!prefersLocal && (snapshot?.status == nil || snapshot?.isRecent(at: now) == false))
        let menuState = needsMenuCheck && AXIsProcessTrusted()
            ? controls(AXUIElementCreateApplication(active.pid)).state : nil
        guard let snapshot else {
            lastReadMode = nil
            resetClock()
            if menuState == .paused { return .stopped }
            return .failure(NetEaseReadError.missingPlaybackRecord)
        }

        let audioState = snapshot.isRecent(at: now) && menuState == nil && snapshot.status == nil
            ? NetEaseAudioOutput.state(for: [active.process]) : nil
        let date = Date()
        let sampledAt = CACurrentMediaTime()
        let state = snapshot.state(at: date, menu: menuState, audio: audioState)
        let isRecent = snapshot.isRecent(at: date)
        let age = max(0, date.timeIntervalSince(snapshot.writtenAt))
        let report = isRecent && snapshot.hasRecordedProgress && snapshot.playbackAnchor == snapshot.writtenAt
            ? NetEasePlaybackClock.ProgressReport(writtenAt: snapshot.writtenAt,
                                                  phaseStart: snapshot.progress.position + age - sampledAt)
            : nil
        // Retain the last position when the client stops writing progress, including
        // when it is paused with its window closed.
        let holdsLastPosition = !isRecent && snapshot.status?.state != .paused && menuState != .paused
        return publish(localTrack(snapshot, position: snapshot.position(at: date, state: state)), state: state,
                       canSeek: snapshot.hasRecordedProgress && active.commandURL != nil,
                       mode: holdsLastPosition ? "last-player-position" : "local-player",
                       holdsLastPosition: holdsLastPosition, sampledAt: sampledAt, progressReport: report)
    }

    private func localTrack(_ snapshot: NetEaseLocalPlayback.Snapshot, position: TimeInterval) -> NetEaseBarTrack {
        let progress = snapshot.progress
        if let statusSong = snapshot.status?.metadata {
            cachedMetadata = CachedMetadata(
                id: progress.id,
                song: statusSong,
                history: nil,
                fetchedAt: ProcessInfo.processInfo.systemUptime
            )
            return NetEaseBarTrack(title: statusSong.title, artist: statusSong.artist, id: progress.id,
                                   position: position, duration: max(position, statusSong.duration),
                                   album: statusSong.album, artworkURL: statusSong.artworkURL)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let song: NetEaseQueueSong?
        let match: NetEaseHistoryEntry?
        if let cached = cachedMetadata, cached.id == progress.id,
           cached.song != nil || cached.history != nil || uptime - cached.fetchedAt < 4 {
            song = cached.song
            match = cached.history
        } else {
            let queueSong = playingQueue.song(id: progress.id, title: "", artist: "")
            let history = queueSong == nil ? historyStore.latestSong() : nil
            let historyMatch = history?.id == progress.id ? history : nil
            cachedMetadata = CachedMetadata(id: progress.id, song: queueSong, history: historyMatch, fetchedAt: uptime)
            song = queueSong
            match = historyMatch
        }
        return NetEaseBarTrack(title: song?.title ?? match?.title ?? "网易云音乐",
                               artist: song?.artist ?? match?.artist ?? "", id: progress.id,
                               position: position, duration: max(position, song?.duration ?? match?.duration ?? progress.duration),
                               album: song?.album ?? match?.album ?? "", artworkURL: song?.artworkURL ?? match?.artworkURL)
    }

    private func publish(_ info: NetEaseBarTrack, state: PlayerState, canSeek: Bool, mode: String,
                         holdsLastPosition: Bool, sampledAt: TimeInterval,
                         progressReport: NetEasePlaybackClock.ProgressReport?) -> PlaybackMonitor.Update {
        if lastReadMode != mode {
            lastReadMode = mode
            DiagnosticLogger.shared.info("NetEase playback active; mode=\(mode)")
        }
        let position = clock.update(track: info, state: state, at: sampledAt, holdsLastPosition: holdsLastPosition,
                                    progressReport: progressReport)
        return .track(TrackInfo(title: info.title, artist: info.artist, album: info.album,
                                duration: info.duration, position: position, state: state,
                                source: .netease, sourceTrackID: info.id, artworkURL: info.artworkURL, canSeek: canSeek,
                                positionSampledAt: sampledAt, positionRate: clock.rate))
    }

    private func player(in app: AXUIElement) -> NetEasePlayerBar? {
        let windows = axList(app, kAXWindowsAttribute)
        let main = axElement(ax(app, kAXMainWindowAttribute))
        // Preferences and floating lyrics can become the main window. Retain a
        // previously identified player while it exists, then try a standard window.
        let standard = windows.prefix(6).filter {
            axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole && ax($0, kAXModalAttribute) as? Bool != true
        }
        let cached = playbackWindow.flatMap { candidate in windows.first { CFEqual(candidate, $0) } }
        let mainStandard = main.flatMap { candidate in standard.first { CFEqual(candidate, $0) } }
        let candidates = [cached, mainStandard, main].compactMap { $0 } + standard + windows.prefix(6)
        var tried: [AXUIElement] = []
        var fallback: NetEasePlayerBar?
        for candidate in candidates where !tried.contains(where: { CFEqual($0, candidate) }) {
            let bar = NetEasePlayerBar(window: candidate, queue: playingQueue)
            if bar.info != nil {
                playbackWindow = candidate
                return bar
            }
            if fallback == nil || bar.explicitlyStopped { fallback = bar }
            tried.append(candidate)
            if tried.count == 3 { break }
        }
        playbackWindow = nil
        return fallback
    }

    private struct Controls {
        var play: AXUIElement?
        var pause: AXUIElement?
        var toggle: AXUIElement?
        var next: AXUIElement?
        var previous: AXUIElement?

        var state: PlayerState? {
            if pause != nil && play == nil { return .playing }
            if play != nil && pause == nil { return .paused }
            return nil
        }

        func target(for command: String) -> AXUIElement? {
            switch command {
            case "next": return next
            case "previous": return previous
            case "pause": return pause
            case "play": return play
            case "toggle": return toggle ?? (state == .playing ? pause : (state == .paused ? play : nil))
            default: return nil
            }
        }
    }

    private func controls(_ app: AXUIElement) -> Controls {
        var result = Controls()
        guard let menuBar = axElement(ax(app, kAXMenuBarAttribute)),
              let controlMenu = axList(menuBar, kAXChildrenAttribute).first(where: {
                  ["控制", "播放控制", "controls", "control", "playback"].contains(axString($0, kAXTitleAttribute).lowercased())
              }) else { return result }
        // Inspect only immediate items of the player's own transport menu.
        let items = axList(controlMenu, kAXChildrenAttribute).flatMap { axList($0, kAXChildrenAttribute) }
        for item in items where ax(item, kAXEnabledAttribute) as? Bool != false {
            switch NetEasePlayerBar.transport(axString(item, kAXTitleAttribute)) {
            case "play": result.play = item
            case "pause": result.pause = item
            case "toggle": result.toggle = item
            case "next": result.next = item
            case "previous": result.previous = item
            default: break
            }
        }
        return result
    }

    func control(_ arguments: [String], active: () -> Bool) -> Bool {
        guard let action = arguments.first, let process = runningApps().first, active() else { return false }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        let trusted = AXIsProcessTrusted()
        let commandURL = NetEaseClientCommand.applicationURL(for: process)
        if action == "seek" {
            guard arguments.count == 2, let seconds = Double(arguments[1]), seconds.isFinite, seconds >= 0 else { return false }
            if let commandURL, let before = localPlayback.read(), before.hasRecordedProgress {
                let target = min(seconds, before.progress.duration)
                if NetEaseClientCommand.seek(target).send(to: commandURL, active: active) {
                    return confirmSeek(to: target, from: before, active: active)
                }
            }
            guard trusted else { return false }
            enableRendererAccessibility(app)
            guard let bar = player(in: app) else { return false }
            return active() && bar.seek(to: seconds, active: active)
        }
        guard arguments.count == 1 else { return false }

        if let commandURL {
            let command: NetEaseClientCommand?
            switch action {
            case "next": command = .next
            case "previous": command = .previous
            case "play": command = .resume
            case "pause": command = .pause
            case "toggle": command = toggleCommand(for: process, prefersMenuFallback: trusted)
            default: return false
            }
            if let command, command.send(to: commandURL, active: active) {
                remember(command, for: process.processIdentifier)
                return true
            }
        }
        guard trusted, active() else {
            DiagnosticLogger.shared.warning("NetEase playback command unavailable; command=\(action); axTrusted=\(trusted)")
            return false
        }
        enableRendererAccessibility(app)
        return issue(action, in: app, active: active)
    }

    private func toggleCommand(for process: NSRunningApplication, prefersMenuFallback: Bool) -> NetEaseClientCommand? {
        let snapshot = localPlayback.read()
        let audio = snapshot?.status == nil ? NetEaseAudioOutput.state(for: [process]) : nil
        let observed = snapshot?.state(at: Date(), menu: nil, audio: audio) ?? audio
        if let intent = playIntent, intent.pid == process.processIdentifier,
           intent.trackID == snapshot?.progress.id, ProcessInfo.processInfo.systemUptime < intent.deadline {
            return intent.state == .playing ? .pause : .resume
        }
        guard observed != nil || !prefersMenuFallback else { return nil }
        return observed == .playing ? .pause : .resume
    }

    private func remember(_ command: NetEaseClientCommand, for pid: pid_t) {
        let requested: PlayerState
        switch command {
        case .resume: requested = .playing
        case .pause: requested = .paused
        default: playIntent = nil; return
        }
        playIntent = PlayIntent(state: requested, pid: pid, trackID: localPlayback.read()?.progress.id,
                                deadline: ProcessInfo.processInfo.systemUptime + 1.5)
    }

    private func confirmSeek(to target: TimeInterval, from old: NetEaseLocalPlayback.Snapshot, active: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        repeat {
            guard active() else { return false }
            if let fresh = localPlayback.read() {
                guard fresh.progress.id == old.progress.id else { return false }
                // Progress reports are whole seconds and may arrive after
                // playback has moved on a little from the requested position.
                if fresh.hasRecordedProgress, abs(fresh.progress.position - target) <= 2,
                   fresh.writtenAt > old.writtenAt || fresh.progress != old.progress
                    || abs(old.progress.position - target) < 1 { return true }
            }
            Thread.sleep(forTimeInterval: 0.06)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func issue(_ action: String, in app: AXUIElement, active: () -> Bool) -> Bool {
        let menu = controls(app)
        let expected: PlayerState? = action == "play" ? .playing : (action == "pause" ? .paused : nil)
        if let expected, menu.state == expected { return true }
        if let item = menu.target(for: action) { return active() && axPress(item) }
        guard let bar = player(in: app) else { return false }
        let observed = bar.state ?? bar.info.map { motion.observe($0, at: ProcessInfo.processInfo.systemUptime) }
        if let expected, observed == expected { return true }
        if let item = bar.button(for: action) { return active() && axPress(item) }
        if expected != nil, let observed, observed == .paused || observed == .playing,
           let toggle = menu.toggle ?? bar.button(for: "toggle") { return active() && axPress(toggle) }
        return false
    }
}

private func ax(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func axList(_ element: AXUIElement, _ key: String) -> [AXUIElement] {
    (ax(element, key) as? [AXUIElement]) ?? []
}

private func axString(_ element: AXUIElement, _ key: String) -> String {
    (ax(element, key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func axPress(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

private func axRect(_ element: AXUIElement) -> CGRect? {
    guard let position = ax(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = ax(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
          AXValueGetValue(size as! AXValue, .cgSize, &s), s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

/// Values from the visible playback strip. Geometry scopes text and links to the
/// current player, even while a playlist with different track links is open.
struct NetEaseBarField {
    var role: String
    var text: String
    var hint: String = ""
    var transportAction: String? = nil
    var url: URL? = nil
    var valueDescription = ""
    var sliderValue: Double? = nil
    var sliderMin: Double? = nil
    var sliderMax: Double? = nil
    var rect: CGRect

    func looksLikeTimeline(in frame: CGRect) -> Bool {
        guard role == kAXSliderRole else { return false }
        let label = (text + " " + hint).lowercased()
        if label.contains("音量") || label.contains("volume") { return false }
        return label.contains("进度") || label.contains("progress") || label.contains("seek")
            || label.contains("position") || rect.width > frame.width * 0.33
    }
}

struct NetEaseBarTrack {
    var title: String
    var artist: String
    var id: String?
    var position: Double
    var duration: Double
    var album: String = ""
    var artworkURL: URL? = nil

    static func read(_ fields: [NetEaseBarField], in frame: CGRect, queue: NetEasePlayingQueue? = nil) -> Self? {
        let ordered = fields.sorted {
            let rowA = ($0.rect.midY / 4).rounded(), rowB = ($1.rect.midY / 4).rounded()
            if rowA != rowB { return rowA < rowB }
            return $0.rect.minX < $1.rect.minX
        }
        guard let name = identity(in: ordered, frame: frame) else { return nil }
        let visibleClock = time(in: ordered, frame: frame)
        let song = queue?.song(id: name.id, title: name.title, artist: name.artist, duration: visibleClock?.1)
        guard let (position, duration) = visibleClock ?? time(in: ordered, frame: frame, knownDuration: song?.duration),
              duration > 0, position <= duration else { return nil }
        return Self(title: song?.title ?? name.title, artist: song?.artist ?? name.artist, id: song?.id ?? name.id,
                    position: position, duration: duration, album: song?.album ?? "", artworkURL: song?.artworkURL)
    }

    private static func identity(in ordered: [NetEaseBarField], frame: CGRect) -> (title: String, artist: String, id: String?)? {
        // Names are in the left part of the playback strip, away from unrelated page links.
        let names = ordered.filter {
            [NSAccessibility.Role.link.rawValue, kAXStaticTextRole, kAXHeadingRole, kAXGroupRole].contains($0.role)
                && $0.transportAction == nil
                && $0.rect.midX < frame.minX + frame.width * (frame.width < 550 ? 0.85 : 0.43)
                && isName($0.text)
        }
        let songLink = names.first { linkedID($0.url, type: "song") != nil }
        var artistNames: [String] = []
        for name in names where linkedID(name.url, type: "artist") != nil && !artistNames.contains(name.text) {
            artistNames.append(name.text)
        }
        let heading = names.first { $0.role == kAXHeadingRole && !artistNames.contains($0.text) }
        guard let song = songLink ?? heading ?? names.first(where: { !artistNames.contains($0.text) }) else { return nil }
        var title = normalizedName(song.text)
        var artist = artistNames.joined(separator: " / ")
        for prefix in ["网易云音乐 - ", "NetEase Cloud Music - "] where title.hasPrefix(prefix) {
            title.removeFirst(prefix.count)
        }
        let separators = [" - ", " — ", " · ", " | "]
        if let separator = separators.compactMap({ title.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }),
           songLink == nil || normalizedName(artist) == String(title[separator.upperBound...]) {
            let suffix = String(title[separator.upperBound...])
            if artist.isEmpty || artistNames.contains(suffix) || suffix == normalizedName(artist) {
                if artist.isEmpty { artist = suffix }
                title = String(title[..<separator.lowerBound])
            }
        }
        if artist.isEmpty {
            artist = names.first { $0.text != song.text && normalizedName($0.text) != title &&
                $0.role != kAXHeadingRole && $0.rect.minY >= song.rect.minY - 3 }?.text ?? ""
        }
        guard !title.isEmpty else { return nil }
        return (title, artist, linkedID(song.url, type: "song"))
    }

    static func time(in fields: [NetEaseBarField], frame: CGRect, knownDuration: Double? = nil) -> (Double, Double)? {
        var clocks: [(value: Double, x: CGFloat)] = []
        let sliders = fields.filter { $0.looksLikeTimeline(in: frame) }
        for field in fields {
            let candidates = field.valueDescription.isEmpty ? [field.text] : [field.valueDescription, field.text]
            for candidate in candidates {
                let parts = candidate.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "／" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if parts.count == 2, let pos = clock(parts[0]), let total = clock(parts[1]) { return (pos, total) }
                if parts.count == 1, let value = clock(parts[0]) {
                    // Chromium can expose both a labelled group and its child text.
                    if !clocks.contains(where: { $0.value == value && abs($0.x - field.rect.midX) < 6 }) {
                        clocks.append((value, field.rect.midX))
                    }
                    break
                }
            }
        }
        if clocks.count == 2 {
            let pair = clocks.sorted { $0.x < $1.x }
            return (pair[0].value, pair[1].value)
        }
        if sliders.isEmpty, clocks.count == 1, let knownDuration, knownDuration.isFinite,
           clocks[0].value < knownDuration - 1 {
            return (clocks[0].value, knownDuration)
        }
        // The clock to the right of a timeline is the duration. Some versions
        // expose seconds directly, while others expose a percentage or fraction.
        guard sliders.count == 1, let slider = sliders.first,
              let min = slider.sliderMin, let max = slider.sliderMax, let value = slider.sliderValue,
              min.isFinite, max.isFinite, max > min, value.isFinite, value >= min, value <= max else { return nil }
        let duration: Double
        if clocks.count == 1, clocks[0].x >= slider.rect.maxX || (min == 0 && abs(max - clocks[0].value) < 1) {
            duration = clocks[0].value
        } else if let knownDuration, clocks.count <= 1 {
            duration = knownDuration
        } else { return nil }
        guard duration.isFinite, duration > 0 else { return nil }
        return ((value - min) / (max - min) * duration, duration)
    }

    private static func normalizedName(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clock(_ text: String) -> Double? {
        let components = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              components.dropFirst().allSatisfy({ $0.count == 2 && Int($0)! < 60 }) else { return nil }
        return components.reduce(0) { $0 * 60 + Double($1)! }
    }

    private static func isName(_ value: String) -> Bool {
        guard !value.isEmpty, clock(value) == nil, !value.contains(where: { $0.isNewline }),
              value.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil,
              !value.contains(" / ") || !value.contains(":") else { return false }
        return !["mv", "vip", "sq", "hi-res", "hires", "极高", "无损", "标准", "超清母带",
                 "音质", "词", "歌词", "列表", "播放列表", "倍速", "喜欢"].contains(value.lowercased())
    }

    private static func linkedID(_ url: URL?, type: String) -> String? {
        guard let url, let host = url.host?.lowercased(),
              host == "music.163.com" || host.hasSuffix(".music.163.com") else { return nil }
        // The official site uses both /song?id=… and /#/song?id=… links.
        let normalized = url.absoluteString.replacingOccurrences(of: "/#/", with: "/")
        guard let components = URLComponents(string: normalized) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard let index = path.firstIndex(of: type) else { return nil }
        let id = components.queryItems?.first { $0.name == "id" }?.value
            ?? path.dropFirst(index + 1).first
        guard let id, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return id
    }
}

struct NetEaseClockObservation {
    private var last: NetEaseBarTrack?
    private var lastChange: TimeInterval = 0
    private var state = PlayerState.unknown

    mutating func observe(_ track: NetEaseBarTrack, at now: TimeInterval) -> PlayerState {
        defer { last = track }
        guard let last, last.title == track.title, last.artist == track.artist, last.id == track.id,
              last.duration == track.duration else {
            lastChange = now
            state = .unknown
            return state
        }
        if track.position != last.position {
            let elapsed = now - lastChange
            let delta = track.position - last.position
            // A seek while paused must not be reported as playback.
            state = delta > 0 && abs(delta - elapsed) < 1.2 ? .playing : .unknown
            lastChange = now
        } else if now - lastChange >= 2.2 {
            state = .paused
        }
        return state
    }
}

struct NetEasePlaybackClock {
    struct ProgressReport {
        let writtenAt: Date
        // Subtract the monotonic write time from the whole-second position.
        let phaseStart: TimeInterval
    }

    private struct Anchor {
        let track: NetEaseBarTrack
        let time: TimeInterval
        let position: TimeInterval
        let state: PlayerState
        let rate: Double
    }

    // NetEase saves elapsed time in whole seconds. Allow for the time between
    // recording the whole second and writing it out.
    private static let reportTolerance: TimeInterval = 1.25
    private static let progressWindow: TimeInterval = 1.2
    private var anchor: Anchor?
    private var lastProgressReport: Date?
    private var phaseRange: ClosedRange<TimeInterval>?
    var rate: Double { anchor?.rate ?? 1 }

    mutating func update(track: NetEaseBarTrack, state: PlayerState, at time: TimeInterval,
                         holdsLastPosition: Bool = false, progressReport: ProgressReport? = nil) -> TimeInterval {
        let previous = anchor.flatMap { matches(track, $0.track) ? $0 : nil }
        let predicted = previous.map {
            let elapsed = $0.state == .playing ? max(0, time - $0.time) * $0.rate : 0
            return min(track.duration, $0.position + elapsed)
        }
        var position = track.position
        var rate = 1.0
        if state == .playing, !holdsLastPosition, let progressReport {
            let continuesPlaying = previous?.state == .playing
            if !continuesPlaying {
                lastProgressReport = nil
                phaseRange = nil
            }
            var canReanchor = false
            if lastProgressReport != progressReport.writtenAt {
                // For a report of n whole seconds, the estimated position at
                // the write lies in [n, n + progressWindow]. Keep the overlap
                // even when the individual reports differ by nearly a second.
                let observed = progressReport.phaseStart...(progressReport.phaseStart + Self.progressWindow)
                let lower = max(phaseRange?.lowerBound ?? observed.lowerBound, observed.lowerBound)
                let upper = min(phaseRange?.upperBound ?? observed.upperBound, observed.upperBound)
                canReanchor = phaseRange == nil || lower > upper
                phaseRange = lower <= upper ? lower...upper : observed
                lastProgressReport = progressReport.writtenAt
            }
            if let range = phaseRange {
                let estimate = min(track.duration, max(0, time + (range.lowerBound + range.upperBound) * 0.5))
                if continuesPlaying, let predicted, !canReanchor || abs(estimate - predicted) <= Self.reportTolerance {
                    position = predicted
                    rate += min(0.25, max(-0.25, (estimate - predicted) / 2))
                } else {
                    position = estimate
                }
            }
        } else {
            lastProgressReport = nil
            phaseRange = nil
            if let previous, let predicted {
                let correction = position - predicted
                if holdsLastPosition {
                    position = predicted
                } else if state == .playing || previous.state == .playing {
                    // Keep a continuous timeline for compatible window readings.
                    if abs(correction) <= Self.reportTolerance, state == previous.state || correction < 0 {
                        position = predicted
                    }
                } else if track.position == previous.track.position {
                    position = previous.position
                }
            }
        }
        position = min(track.duration, position)
        anchor = Anchor(track: track, time: time, position: position, state: state, rate: rate)
        return position
    }

    private func matches(_ lhs: NetEaseBarTrack, _ rhs: NetEaseBarTrack) -> Bool {
        if let id = lhs.id { return id == rhs.id }
        return rhs.id == nil && lhs.title == rhs.title && lhs.artist == rhs.artist
            && abs(lhs.duration - rhs.duration) <= 2
    }
}

private struct NetEasePlayerBar {
    let entries: [(field: NetEaseBarField, element: AXUIElement)]
    let frame: CGRect
    let info: NetEaseBarTrack?

    init(window: AXUIElement, queue: NetEasePlayingQueue) {
        guard let frame = axRect(window) else {
            self.frame = .zero
            entries = []
            info = nil
            return
        }
        self.frame = frame
        let height = frame.height < 180 ? frame.height : min(96, frame.height * 0.2)
        let band = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        var pending = [window]
        var entries: [(NetEaseBarField, AXUIElement)] = []
        let limit = 280
        let values: [String] = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                                kAXHelpAttribute, kAXURLAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                kAXValueDescriptionAttribute]
        var inspected = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.85
        // The footer usually follows the page content in a Chromium web area.
        // Visit later siblings first so a long playlist cannot consume the budget
        // before any of the deeper footer elements have been examined.
        while inspected < limit, ProcessInfo.processInfo.systemUptime < deadline, let element = pending.popLast() {
            inspected += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, values as CFArray, [], &raw) == .success,
                  let attributes = raw as? [Any], attributes.count == values.count,
                  let role = attributes[0] as? String else { continue }
            let rect = Self.rect(position: attributes[6], size: attributes[7])
            if let rect, !rect.intersects(band) { continue }
            if [kAXTableRole, kAXOutlineRole, kAXListRole, kAXMenuRole, kAXRowRole].contains(role) { continue }
            if let rect, band.contains(CGPoint(x: rect.midX, y: rect.midY)),
               [kAXStaticTextRole, NSAccessibility.Role.link.rawValue, kAXGroupRole, kAXButtonRole, kAXHeadingRole, kAXSliderRole].contains(role) {
                let texts = [attributes[1], attributes[2], attributes[3], attributes[4]]
                    .compactMap { (($0 as? String) ?? ($0 as? NSAttributedString)?.string)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let action = texts.compactMap(Self.transport).first
                let clickable = action != nil && (role == kAXButtonRole ||
                    ([kAXGroupRole, NSAccessibility.Role.link.rawValue].contains(role) && axActions(element).contains(kAXPressAction)))
                let field = NetEaseBarField(role: role, text: texts.first ?? "",
                                            hint: texts.joined(separator: " "), transportAction: clickable ? action : nil,
                                            url: (attributes[5] as? URL) ?? (attributes[5] as? String).flatMap(URL.init(string:)),
                                            valueDescription: attributes[8] as? String ?? "",
                                            sliderValue: (attributes[2] as? NSNumber)?.doubleValue,
                                            sliderMin: role == kAXSliderRole ? (ax(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue : nil,
                                            sliderMax: role == kAXSliderRole ? (ax(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue : nil,
                                            rect: rect)
                entries.append((field, element))
            }
            if [kAXStaticTextRole, kAXImageRole, kAXButtonRole, kAXSliderRole].contains(role) { continue }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 80, &children) == .success,
                  let elements = children as? [AXUIElement] else { continue }
            pending.append(contentsOf: elements)
            if elements.count == 80 {
                var count = 0
                if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count > 80,
                   AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, max(80, count - 16), 16, &children) == .success,
                   let tail = children as? [AXUIElement] { pending.append(contentsOf: tail) }
            }
        }
        self.entries = entries
        info = NetEaseBarTrack.read(entries.map { $0.0 }, in: frame, queue: queue)
    }

    private static func rect(position: Any, size: Any) -> CGRect? {
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0 && extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    var state: PlayerState? {
        let pause = button(for: "pause") != nil
        let play = button(for: "play") != nil
        guard pause != play else { return nil }
        return pause ? .playing : .paused
    }

    var explicitlyStopped: Bool {
        if let times = NetEaseBarTrack.time(in: entries.map(\.field), frame: frame), times.1 == 0, times.0 == 0 { return true }
        return entries.contains { ["暂无播放歌曲", "还没有播放歌曲", "No song playing"].contains($0.field.text) }
    }

    static func transport(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "play", "播放", "继续播放", "开始播放": return "play"
        case "pause", "暂停", "暂停播放": return "pause"
        case "play/pause", "play / pause", "播放/暂停", "播放 / 暂停": return "toggle"
        case "next", "next track", "next song", "下一首", "下一个": return "next"
        case "previous", "previous track", "previous song", "上一首", "上一个": return "previous"
        default: return nil
        }
    }

    func button(for action: String) -> AXUIElement? {
        let matches = entries.filter {
            guard let name = $0.field.transportAction else { return false }
            return name == action || (action == "toggle" && (name == "play" || name == "pause"))
        }
        return matches.count == 1 ? matches[0].element : nil
    }

    private enum SliderControl {
        case direct
        case steps(size: Double)
    }

    private func seekControl(duration: TimeInterval) -> (element: AXUIElement, min: Double, max: Double, control: SliderControl)? {
        let sliders = entries.filter { $0.field.looksLikeTimeline(in: frame) }
        guard sliders.count == 1, let slider = sliders.first,
              let min = slider.field.sliderMin, let max = slider.field.sliderMax,
              min.isFinite, max.isFinite, max > min else { return nil }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(slider.element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return (slider.element, min, max, .direct) }
        let actions = axActions(slider.element)
        guard actions.contains(kAXIncrementAction), actions.contains(kAXDecrementAction),
              let step = (ax(slider.element, kAXValueIncrementAttribute) as? NSNumber)?.doubleValue,
              let current = slider.field.sliderValue, (min...max).contains(current),
              NetEaseSeekSteps.canReachWholeTrack(range: max - min, step: step, duration: duration) else { return nil }
        return (slider.element, min, max, .steps(size: step))
    }

    func seek(to seconds: TimeInterval, active: () -> Bool) -> Bool {
        guard let info, let slider = seekControl(duration: info.duration), active() else { return false }
        let range = slider.max - slider.min
        let target = slider.min + min(1, max(0, seconds / info.duration)) * range
        func read() -> Double? {
            guard let value = (ax(slider.element, kAXValueAttribute) as? NSNumber)?.doubleValue,
                  (slider.min...slider.max).contains(value) else { return nil }
            return value
        }
        let tolerance = range / info.duration // one second, matching the visible clock
        switch slider.control {
        case .direct:
            guard AXUIElementSetAttributeValue(slider.element, kAXValueAttribute as CFString, target as NSNumber) == .success else { return false }
            // A successful AX reply can precede the new playback position.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            repeat {
                guard active() else { return false }
                if let value = read(), abs(value - target) <= tolerance { return true }
                Thread.sleep(forTimeInterval: 0.04)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        case .steps(let size):
            guard var value = read() else { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 2.5
            // One acknowledged movement at a time. Do not enqueue a burst of
            // asynchronous presses or chase an unreachable target indefinitely.
            for _ in 0...NetEaseSeekSteps.limit {
                guard active() else { return false }
                if abs(target - value) <= max(size / 2, tolerance) { return true }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let increasing = value < target
                let action = increasing ? kAXIncrementAction : kAXDecrementAction
                guard AXUIElementPerformAction(slider.element, action as CFString) == .success else { return false }
                let pollUntil = ProcessInfo.processInfo.systemUptime + 0.16
                var changed: Double?
                repeat {
                    guard active(), let updated = read() else { return false }
                    if increasing ? updated > value : updated < value { changed = updated; break }
                    Thread.sleep(forTimeInterval: 0.008)
                } while ProcessInfo.processInfo.systemUptime < pollUntil
                guard let changed else { return false }
                value = changed
            }
            return false
        }
    }
}

private func axActions(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
    return actions as? [String] ?? []
}

enum NetEaseSeekSteps {
    static let limit = 128

    static func canReachWholeTrack(range: Double, step: Double, duration: Double) -> Bool {
        guard range.isFinite, step.isFinite, duration.isFinite, range > 0, step > 0, duration > 0 else { return false }
        let count = range / step
        // Round at most one second away from the requested lyric line, with a
        // bounded number of targeted accessibility actions for the entire track.
        return count >= 1 && ceil(count) <= Double(limit) && duration / count <= 2
    }
}
