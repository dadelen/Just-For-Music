import AppKit
import CoreText
import QuartzCore

final class MenuBarController: NSObject {
    private enum LyricsTitle {
        case text(String)
        case synced(TrackInfo, LyricsDocument, sampledAt: CFTimeInterval)
    }

    private static let footerHeight: CGFloat = 46
    private static let lyricSampleHorizon: TimeInterval = 1.5
    private static let playbackItemLength: CGFloat = 78
    // A single unified status item keeps all three transport controls strictly together.
    private let playbackStatusItem = MenuBarController.makeStatusItem("Playback.Controls", length: playbackItemLength)
    private let statusItem = MenuBarController.makeStatusItem("Lyrics", length: 180)
    private let playerPanel = PlayerPanel(
        contentRect: NSRect(x: 0, y: 0, width: MenuPlayerView.size.width,
                            height: MenuPlayerView.size.height + MenuBarController.footerHeight),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let statusView = StatusItemContentView()
    private let lyricButton = ActionButton()
    private let karaokeTitleView = KaraokeStatusTitleView()
    private let playerView = MenuPlayerView()
    private let playerFade = PanelFade()
    private var playerTrack: TrackInfo?
    private var playerMessage = "打开\(AppPreferences.playbackSource.title)，开始播放"
    private var playerArtwork: NSImage?
    private var playerArtworkNeedsUpdate = true
    private var latestTitle = LyricsTitle.text("♫ 歌词")
    private var floatingLyricsVisible: Bool
    private var lyricsItemWidth: CGFloat = 180
    private var lyricsVisibility: CGFloat
    private var visibilityTimer: Timer?
    private var lineAdvanceTimer: Timer?
    private var screensAwake = true
    private var statusWindowOccluded = false
    private var lastControlState: PlayerState?
    private var localDismissMonitor: Any?
    private var outsideDismissMonitor: Any?
    private var appearanceUpdatePending = false
    var onLyricsAppearanceChanged: ((NSAppearance) -> Void)? {
        didSet { updateLyricsAppearance() }
    }
    var onShowLyrics: (() -> Void)?
    var onSettings: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onOpenMusic: (() -> Void)?
    var onQuit: (() -> Void)?

    init(floatingLyricsVisible: Bool = false) {
        self.floatingLyricsVisible = floatingLyricsVisible
        lyricsVisibility = floatingLyricsVisible ? 0 : 1
        super.init()
        playerView.onSeek = { [weak self] in self?.onSeek?($0) }
        playerView.onOpenMusic = { [weak self] in
            self?.dismissPlayer()
            self?.onOpenMusic?()
        }
        configurePlayerPanel()
        configurePlaybackStatusItem()
        configureStatusItem()
        // The lyrics item is hidden while the floating card is open.
        if let button = playbackStatusItem.button {
            let observer = StatusItemContentView()
            observer.onAppearanceChanged = { [weak self] in self?.scheduleAppearanceUpdate() }
            button.addSubview(observer)
        }
    }

    private static func makeStatusItem(_ name: NSStatusItem.AutosaveName, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        return item
    }

    private func configurePlayerPanel() {
        playerPanel.backgroundColor = .clear
        playerPanel.isOpaque = false
        playerPanel.hasShadow = true
        playerPanel.level = .popUpMenu
        playerPanel.hidesOnDeactivate = false
        playerPanel.isReleasedWhenClosed = false
        playerPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        playerPanel.title = "播放器"
        let surface = GlassSurface(cornerRadius: MenuPlayerView.cornerRadius)
        playerPanel.contentView = surface
        playerView.frame.origin = NSPoint(x: 0, y: Self.footerHeight)
        surface.content.addSubview(playerView)

        let inset = MenuPlayerView.horizontalInset
        let divider = NSBox(frame: NSRect(x: inset, y: Self.footerHeight,
                                          width: playerPanel.frame.width - 2 * inset, height: 1))
        divider.boxType = .separator
        surface.content.addSubview(divider)

        let lyrics = ActionButton(title: "歌词") { [weak self] in
            self?.dismissPlayer()
            self?.onShowLyrics?()
        }
        let settings = ActionButton(title: "设置") { [weak self] in
            self?.dismissPlayer()
            self?.onSettings?()
        }
        let quit = ActionButton(title: "退出") { [weak self] in
            self?.dismissPlayer { [weak self] in self?.onQuit?() }
        }
        let buttonGap: CGFloat = 8
        let buttonWidth = (playerPanel.frame.width - 2 * inset - 2 * buttonGap) / 3
        for (index, button) in [lyrics, settings, quit].enumerated() {
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.setAccessibilityLabel(button.title)
            button.frame = NSRect(x: inset + CGFloat(index) * (buttonWidth + buttonGap), y: 7, width: buttonWidth, height: 32)
            surface.content.addSubview(button)
        }
    }

    func setArtwork(_ image: NSImage?) {
        playerArtwork = image
        playerArtworkNeedsUpdate = true
        if playerPanel.isVisible { updatePlayerArtwork() }
    }

    private func updatePlayer(track: TrackInfo?, message: String = "") {
        playerTrack = track
        playerMessage = message
        if playerPanel.isVisible { playerView.update(track: track, message: message) }
    }

    private func updatePlayerArtwork() {
        guard playerArtworkNeedsUpdate else { return }
        playerView.setArtwork(playerArtwork)
        playerArtworkNeedsUpdate = false
    }

    func resetPlaybackClock() { karaokeTitleView.deactivate() }
    func discardPendingSeek() { playerView.discardPendingSeek() }

    func updateKaraokeProgress(track: TrackInfo, lyrics: LyricsDocument) {
        updatePlayer(track: track)
        updateControls(track)
        updateTitle(.synced(track, lyrics, sampledAt: CACurrentMediaTime()))
    }

    func apply(status: AppStatus) {
        updateControls(status.track)
        switch status {
        case .showing(let track, let lyrics, _):
            updatePlayer(track: track)
            updateTitle(.synced(track, lyrics, sampledAt: CACurrentMediaTime()))
        case .loadingLyrics(let track), .noLyrics(let track, _):
            updatePlayer(track: track)
            updateTitle(.text(track.title))
        case .error(let message):
            updatePlayer(track: nil, message: message)
            updateTitle(.text("音乐连接中断"))
        case .idle, .stopped, .musicNotRunning:
            updatePlayer(track: nil, message: "打开\(AppPreferences.playbackSource.title)，开始播放")
            updateTitle(.text("♫ 歌词"))
        }
    }

    private func updateControls(_ track: TrackInfo?) {
        guard lastControlState != track?.state else { return }
        lastControlState = track?.state
        updatePlaybackItems()
        let playing = track?.state == .playing
        updatePlaybackControlImage(playing: playing)
    }

    private func configurePlaybackStatusItem() {
        guard let button = playbackStatusItem.button else { return }
        button.target = self
        button.action = #selector(playbackControlClicked(_:))
        button.isEnabled = true
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "播放控制 · ⌥ 点击打开播放器"
        button.setAccessibilityLabel("播放控制")
        let prevAction = NSAccessibilityCustomAction(name: "上一首") { [weak self] in
            self?.onPreviousTrack?()
            return true
        }
        let toggleAction = NSAccessibilityCustomAction(name: "播放/暂停") { [weak self] in
            self?.onTogglePlayPause?()
            return true
        }
        let nextAction = NSAccessibilityCustomAction(name: "下一首") { [weak self] in
            self?.onNextTrack?()
            return true
        }
        button.setAccessibilityCustomActions([prevAction, toggleAction, nextAction])
        updatePlaybackControlImage(playing: false)
    }

    private func updatePlaybackControlImage(playing: Bool) {
        guard let button = playbackStatusItem.button else { return }
        let prevIcon = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "上一首")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        let toggleIcon = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "暂停" : "播放")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        let nextIcon = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "下一首")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))

        let icons = [prevIcon, toggleIcon, nextIcon]
        let width = Self.playbackItemLength
        let segmentWidth: CGFloat = width / 3.0
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            for (index, icon) in icons.enumerated() {
                guard let icon else { continue }
                let iconSize = icon.size
                let x = CGFloat(index) * segmentWidth + (segmentWidth - iconSize.width) / 2
                let y = (rect.height - iconSize.height) / 2
                icon.draw(in: NSRect(x: x, y: y, width: iconSize.width, height: iconSize.height))
            }
            return true
        }
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func updatePlaybackItems() {
        let show = floatingLyricsVisible || AppPreferences.statusBarMode != .icon
        if playbackStatusItem.isVisible != show { playbackStatusItem.isVisible = show }
        playbackStatusItem.button?.isEnabled = true
        playbackStatusItem.button?.appearsDisabled = false
    }

    @objc private func playbackControlClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondaryClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.option) == true
            || NSEvent.modifierFlags.contains(.option)
        if secondaryClick {
            statusButtonClicked(sender)
            return
        }
        dismissPlayer()

        let clickX = resolveClickLocationX(sender: sender, event: event)
        let segmentWidth = sender.bounds.width / 3.0
        if clickX < segmentWidth {
            onPreviousTrack?()
        } else if clickX < segmentWidth * 2 {
            onTogglePlayPause?()
        } else {
            onNextTrack?()
        }
    }

    private func resolveClickLocationX(sender: NSStatusBarButton, event: NSEvent?) -> CGFloat {
        let width = sender.bounds.width > 0 ? sender.bounds.width : Self.playbackItemLength
        let midX = width / 2.0

        if let event {
            let eventLoc = sender.convert(event.locationInWindow, from: nil)
            if abs(eventLoc.x - midX) > 0.5 {
                return eventLoc.x
            }
        }

        if let window = sender.window {
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let viewPoint = sender.convert(windowPoint, from: nil)
            if viewPoint.x >= 0 && viewPoint.x <= width {
                return viewPoint.x
            }
        }

        if let event {
            return sender.convert(event.locationInWindow, from: nil).x
        }
        return midX
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: .leftMouseUp)
        statusView.wantsLayer = true
        statusView.layer?.masksToBounds = true
        statusView.onAppearanceChanged = { [weak self] in self?.scheduleAppearanceUpdate() }
        button.addSubview(statusView)
        statusView.addSubview(lyricButton)
        lyricButton.font = .menuBarFont(ofSize: 0)
        lyricButton.layer?.masksToBounds = true
        karaokeTitleView.wantsLayer = true
        lyricButton.addSubview(karaokeTitleView)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusWindowOcclusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screenPowerChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenPowerChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        reloadAppearance()
    }

    private func scheduleAppearanceUpdate() {
        guard !appearanceUpdatePending else { return }
        appearanceUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceUpdatePending = false
            self.updateLyricsAppearance()
        }
    }

    private func updateLyricsAppearance() {
        let items = floatingLyricsVisible ? [playbackStatusItem, statusItem] : [statusItem, playbackStatusItem]
        for item in items where item.isVisible {
            guard let button = item.button, button.window != nil else { continue }
            onLyricsAppearanceChanged?(button.effectiveAppearance.lyricsAppearance)
            return
        }
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard !playerPanel.isVisible || playerFade.isClosing, let window = sender.window else { return }
        let buttonFrame = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(buttonFrame) }
        let available = screen?.visibleFrame
        let menuBarBottom = min(buttonFrame.minY, available?.maxY ?? buttonFrame.minY)
        var left = buttonFrame.minX
        if let available {
            left = max(available.minX + 8, min(left, available.maxX - playerPanel.frame.width - 8))
        }
        playerPanel.setFrameTopLeftPoint(NSPoint(x: left, y: menuBarBottom - 12))
        playerView.update(track: playerTrack, message: playerMessage)
        updatePlayerArtwork()
        playerPanel.ignoresMouseEvents = false
        playerFade.show(playerPanel) { playerPanel.makeKeyAndOrderFront(nil) }
        installDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.dismissPlayerIfOutside(event)
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && event.window === self.playerPanel {
                    self.dismissPlayer()
                    return nil
                }
            } else {
                self.dismissPlayerIfOutside(event)
            }
            return event
        }
    }

    private func dismissPlayerIfOutside(_ event: NSEvent) {
        if let window = event.window {
            guard window !== playerPanel,
                  window !== statusItem.button?.window,
                  window !== playbackStatusItem.button?.window else { return }
        } else {
            // Some status-item events have a screen location but no window.
            for item in [statusItem, playbackStatusItem] where item.isVisible {
                guard let button = item.button, let window = button.window, window.isVisible,
                      window.occlusionState.contains(.visible),
                      window.convertToScreen(button.convert(button.bounds, to: nil)).contains(event.locationInWindow) else { continue }
                return
            }
        }
        dismissPlayer()
    }

    private func removeDismissMonitors() {
        if let localDismissMonitor { NSEvent.removeMonitor(localDismissMonitor) }
        if let outsideDismissMonitor { NSEvent.removeMonitor(outsideDismissMonitor) }
        localDismissMonitor = nil
        outsideDismissMonitor = nil
    }

    private func dismissPlayer(completion: @escaping () -> Void = {}) {
        removeDismissMonitors()
        guard playerPanel.isVisible, !playerFade.isClosing else {
            completion()
            return
        }
        playerView.resetProgressHover()
        playerPanel.ignoresMouseEvents = true
        playerFade.hide(playerPanel, completion: completion)
    }

    func setFloatingLyricsVisible(_ visible: Bool, animated: Bool = true) {
        guard floatingLyricsVisible != visible else { return }
        floatingLyricsVisible = visible
        updatePlaybackItems()
        scheduleAppearanceUpdate()
        if visible { cancelLineAdvance() }
        else { displayLatestTitle(preparingForReveal: true) }

        visibilityTimer?.invalidate()
        visibilityTimer = nil
        let start = lyricsVisibility
        let end: CGFloat = visible ? 0 : 1
        guard start != end, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyLyricsVisibility(end)
            return
        }

        let startedAt = CACurrentMediaTime()
        let duration = 0.24 * abs(end - start)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let fraction = min(1, (CACurrentMediaTime() - startedAt) / duration)
            let eased = fraction * fraction * (3 - 2 * fraction)
            self.applyLyricsVisibility(start + (end - start) * eased)
            if fraction == 1 {
                timer.invalidate()
                self.visibilityTimer = nil
            }
        }
        visibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyLyricsVisibility(_ progress: CGFloat) {
        lyricsVisibility = progress
        statusView.alphaValue = progress
        guard progress > 0 else {
            if statusItem.isVisible { statusItem.isVisible = false }
            karaokeTitleView.isHidden = true
            karaokeTitleView.deactivate()
            return
        }

        let height = NSStatusBar.system.thickness
        let width = max(1, (lyricsItemWidth * progress).rounded())
        if statusItem.length != width { statusItem.length = width }
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Clip at the left edge as the item contracts toward the playback controls.
        lyricButton.frame = NSRect(x: width - lyricsItemWidth, y: 0, width: lyricsItemWidth, height: height)
        karaokeTitleView.frame = lyricButton.bounds
        if !statusItem.isVisible {
            statusItem.isVisible = true
            refreshStatusRendering()
        }
    }

    @objc private func screenParametersChanged() {
        dismissPlayer()
        reloadAppearance()
    }

    @objc private func screenPowerChanged(_ notification: Notification) {
        screensAwake = notification.name == NSWorkspace.screensDidWakeNotification
        refreshStatusRendering()
    }

    @objc private func statusWindowOcclusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === statusItem.button?.window else { return }
        statusWindowOccluded = !window.occlusionState.contains(.visible)
        refreshStatusRendering()
    }

    private var statusLyricsVisible: Bool {
        guard screensAwake, statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private func refreshStatusRendering() {
        let visible = statusLyricsVisible
        karaokeTitleView.renderingVisible = visible
        if visible, !floatingLyricsVisible {
            displayLatestTitle()
        } else if !visible {
            cancelLineAdvance()
        }
    }

    func reloadAppearance() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let constrained = (screen?.auxiliaryTopRightArea?.width ?? 0) > 0 || (screen?.frame.width ?? 1440) < 1500
        let viewportWidth: CGFloat = constrained ? 112 : 180
        lyricsItemWidth = AppPreferences.statusBarMode == .icon ? NSStatusBar.system.thickness : viewportWidth
        updatePlaybackItems()
        applyLyricsVisibility(lyricsVisibility)
        if !floatingLyricsVisible {
            displayLatestTitle()
        }
        karaokeTitleView.reloadColors()
        scheduleAppearanceUpdate()
    }

    deinit {
        visibilityTimer?.invalidate()
        lineAdvanceTimer?.invalidate()
        removeDismissMonitors()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for item in [playbackStatusItem, statusItem] {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func updateTitle(_ title: LyricsTitle) {
        latestTitle = title
        if screensAwake, !floatingLyricsVisible, AppPreferences.statusBarMode != .icon {
            displayLatestTitle()
        }
    }

    private func displayLatestTitle(preparingForReveal: Bool = false) {
        let visible = statusLyricsVisible
        karaokeTitleView.renderingVisible = visible
        if AppPreferences.statusBarMode == .icon {
            cancelLineAdvance()
            karaokeTitleView.deactivate()
            karaokeTitleView.isHidden = true
            lyricButton.setSymbol("music.note", label: "打开播放器")
            statusItem.button?.setAccessibilityLabel("打开播放器")
            return
        }
        // Render one sample before an explicit reveal. During installation of
        // the status item, occlusion is unknown until AppKit reports it.
        guard screensAwake, preparingForReveal || (statusItem.isVisible && (visible || !statusWindowOccluded)) else {
            cancelLineAdvance()
            return
        }
        if lyricButton.image != nil {
            lyricButton.image = nil
            lyricButton.imagePosition = .noImage
        }
        switch latestTitle {
        case .text(let text):
            cancelLineAdvance()
            setTitle(text)
        case .synced(let track, let lyrics, let sampledAt):
            let now = CACurrentMediaTime()
            let origin = track.positionSampledAt ?? sampledAt
            let elapsed = track.state == .playing ? min(Self.lyricSampleHorizon, max(0, now - origin)) : 0
            let position = track.position + elapsed * track.positionRate
            let lineIndex = lyrics.lineIndex(at: position)
            if let lineIndex, !lyrics.lines[lineIndex].isGap {
                setKaraokeTitle(line: lyrics.lines[lineIndex], position: position, isPlaying: track.state == .playing,
                                positionSampledAt: track.positionSampledAt.map { _ in now },
                                positionRate: track.positionRate)
            } else {
                setTitle(track.displayName)
            }
            let next = (lineIndex ?? -1) + 1
            if track.state == .playing, visible, lyrics.lines.indices.contains(next),
               lyrics.lines[next].time - track.position <= Self.lyricSampleHorizon * track.positionRate {
                let delay = (lyrics.lines[next].time - position) / track.positionRate
                scheduleLineAdvance(after: delay)
            } else {
                cancelLineAdvance()
            }
        }
    }

    private func scheduleLineAdvance(after delay: TimeInterval) {
        let fireDate = Date(timeIntervalSinceNow: max(0.01, delay))
        if let timer = lineAdvanceTimer, timer.isValid {
            if abs(timer.fireDate.timeIntervalSince(fireDate)) > 0.005 { timer.fireDate = fireDate }
            return
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.lineAdvanceTimer = nil
            self.displayLatestTitle()
        }
        lineAdvanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelLineAdvance() {
        lineAdvanceTimer?.invalidate()
        lineAdvanceTimer = nil
    }

    private func setTitle(_ title: String) {
        karaokeTitleView.deactivate()
        karaokeTitleView.isHidden = true
        lyricButton.title = title
        statusItem.button?.setAccessibilityLabel("打开播放器，" + title)
    }

    private func setKaraokeTitle(line: LyricLine, position: TimeInterval, isPlaying: Bool,
                                  positionSampledAt: CFTimeInterval?, positionRate: Double) {
        if !lyricButton.title.isEmpty { lyricButton.title = "" }
        let label = "打开播放器，" + line.text
        if let button = statusItem.button, button.accessibilityLabel() != label {
            button.setAccessibilityLabel(label)
        }
        karaokeTitleView.update(line: line, position: position, isPlaying: isPlaying,
                                positionSampledAt: positionSampledAt, positionRate: positionRate)
        karaokeTitleView.isHidden = false
    }

}

private final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private extension NSAppearance {
    var lyricsAppearance: NSAppearance {
        // Resolve the menu bar's vibrancy into a light or dark palette for composited lyrics.
        guard let variant = bestMatch(from: [.darkAqua, .aqua]), variant != name else { return self }
        return NSAppearance(named: variant) ?? self
    }
}

private final class StatusItemContentView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAppearanceChanged?()
    }
}

private final class MenuProgressSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { 12 }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard rect.width > 0 else { return }
        let emphasis = isEnabled ? (controlView as? MenuProgressSlider)?.glassEmphasis ?? 0 : 0
        let brightness = min(1, max(0, emphasis))
        let height = 5 + 4 * emphasis
        let track = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let rail = capsule(in: track)
        let ink = NSColor.labelColor
        let workspace = NSWorkspace.shared
        let needsContrast = workspace.accessibilityDisplayShouldIncreaseContrast
            || workspace.accessibilityDisplayShouldReduceTransparency
        let railOpacity = isEnabled ? (needsContrast ? 0.32 : 0.16 + 0.08 * brightness) : 0.10
        ink.withAlphaComponent(railOpacity).setFill()
        rail.fill()

        guard isEnabled, maxValue > minValue, doubleValue > minValue else { return }
        let progress = min(1, (doubleValue - minValue) / (maxValue - minValue))
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height)
        NSGraphicsContext.saveGraphicsState()
        rail.addClip()
        if !needsContrast && brightness > 0 {
            let glow = NSShadow()
            glow.shadowColor = ink.withAlphaComponent(0.20 * brightness)
            glow.shadowBlurRadius = 4
            glow.set()
        }
        ink.withAlphaComponent(needsContrast ? 1 : 0.72 + 0.23 * brightness).setFill()
        capsule(in: filled).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob(_ knobRect: NSRect) {}

    private func capsule(in rect: NSRect) -> NSBezierPath {
        let radius = min(rect.width, rect.height) / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}

private final class MenuProgressSlider: NSSlider {
    var trackKey: String? {
        didSet {
            if isTracking && oldValue != trackKey { trackingTrackKey = nil }
        }
    }
    var onTrackingFinished: ((Bool) -> Void)?
    var onEmphasisChanged: ((CGFloat) -> Void)?
    private var trackingTrackKey: String?
    private(set) var isTracking = false
    private var hoverTracking: NSTrackingArea?
    private var isHovered = false
    private var emphasisTimer: Timer?
    private(set) var glassEmphasis: CGFloat = 0 {
        didSet {
            needsDisplay = true
            onEmphasisChanged?(min(1, max(0, glassEmphasis)))
        }
    }

    deinit { emphasisTimer?.invalidate() }

    var canSeekCurrentTrack: Bool {
        trackKey != nil && (!isTracking || trackKey == trackingTrackKey)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateGlassEmphasis()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateGlassEmphasis()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingTrackKey = trackKey
        isTracking = true
        updateGlassEmphasis()
        super.mouseDown(with: event)
        let canCommit = canSeekCurrentTrack
        isTracking = false
        if let window { isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        updateGlassEmphasis()
        onTrackingFinished?(canCommit)
    }

    func resetHover() {
        isHovered = false
        updateGlassEmphasis(animated: false)
    }

    private func updateGlassEmphasis(animated: Bool = true) {
        emphasisTimer?.invalidate()
        emphasisTimer = nil
        let from = glassEmphasis
        let to: CGFloat = isTracking || isHovered ? 1 : 0
        guard from != to else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            glassEmphasis = to
            return
        }
        let start = CACurrentMediaTime()
        let angularFrequency = 2 * Double.pi / 0.24
        let damping = angularFrequency * 0.78
        let frequency = (angularFrequency * angularFrequency - damping * damping).squareRoot()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= 0.30 {
                self.glassEmphasis = to
                timer.invalidate()
                self.emphasisTimer = nil
            } else {
                let phase = frequency * elapsed
                let spring = 1 - exp(-damping * elapsed) * (cos(phase) + damping / frequency * sin(phase))
                self.glassEmphasis = from + (to - from) * CGFloat(spring)
            }
        }
        emphasisTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private final class MenuPlayerView: NSView {
    static let size = NSSize(width: 420, height: 120)
    static let cornerRadius: CGFloat = 30
    static let horizontalInset: CGFloat = 20
    private static let artworkSize: CGFloat = 80
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "播放器")
    private let subtitleLabel = NSTextField(labelWithString: "未播放歌曲")
    private let slider = MenuProgressSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private var currentTrack: TrackInfo?
    private var pendingSeek: (position: TimeInterval, deadline: CFTimeInterval)?

    var onSeek: ((TimeInterval) -> Void)?
    var onOpenMusic: (() -> Void)?

    override var intrinsicContentSize: NSSize { Self.size }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        configure()
        update(track: nil, message: "未播放歌曲")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for view in [artworkView, titleLabel, subtitleLabel] {
            addCursorRect(convert(view.bounds, from: view), cursor: .pointingHand)
        }
    }
    private func configure() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 8
        artworkView.layer?.masksToBounds = true
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        setArtworkPlaceholder()

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.alignment = .left
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [artworkView, titleLabel, subtitleLabel] {
            view.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(openMusic))
            )
            view.toolTip = "打开所选播放器"
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("打开所选播放器")
        }

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.cell = MenuProgressSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.sliderType = .linear
        slider.controlSize = .regular
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(seek(_:))
        slider.toolTip = "播放进度"
        slider.setAccessibilityLabel("播放进度")
        slider.onTrackingFinished = { [weak self] canCommit in
            guard let self else { return }
            if canCommit { self.seek(self.slider) }
            self.updateProgress()
        }
        slider.onEmphasisChanged = { [weak self] emphasis in self?.updateTimeLabelEmphasis(emphasis) }

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        updateTimeLabelEmphasis(0)
        remainingLabel.alignment = .right

        addSubview(artworkView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(slider)
        addSubview(elapsedLabel)
        addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: Self.artworkSize),
            artworkView.heightAnchor.constraint(equalToConstant: Self.artworkSize),

            slider.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            slider.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            slider.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),

            elapsedLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: slider.bottomAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            remainingLabel.firstBaselineAnchor.constraint(equalTo: elapsedLabel.firstBaselineAnchor)
        ])
    }

    func update(track: TrackInfo?, message: String? = nil) {
        let previousTrack = currentTrack
        let trackKey = track?.identityKey
        if slider.trackKey != trackKey { pendingSeek = nil }
        slider.trackKey = trackKey
        currentTrack = track
        updateProgress()

        guard let track else {
            titleLabel.stringValue = AppPreferences.playbackSource.title
            let subtitle = message ?? "未播放歌曲"
            if subtitleLabel.stringValue != subtitle { subtitleLabel.stringValue = subtitle }
            subtitleLabel.toolTip = subtitle
            return
        }

        guard track.title != previousTrack?.title || track.artist != previousTrack?.artist
                || track.album != previousTrack?.album else { return }
        titleLabel.stringValue = track.title
        if track.artist.isEmpty {
            subtitleLabel.stringValue = track.album
        } else if track.album.isEmpty {
            subtitleLabel.stringValue = track.artist
        } else {
            subtitleLabel.stringValue = "\(track.artist) · \(track.album)"
        }
        subtitleLabel.toolTip = subtitleLabel.stringValue
    }

    private func updateProgress() {
        guard !slider.isTracking else { return }
        let duration = max(0, currentTrack?.duration ?? 0)
        var position = min(duration, max(0, currentTrack?.position ?? 0))
        if let pendingSeek {
            // Ignore samples from before the seek until Music reports the new position.
            if abs(position - pendingSeek.position) <= 0.5 || CACurrentMediaTime() >= pendingSeek.deadline {
                self.pendingSeek = nil
            } else {
                position = pendingSeek.position
            }
        }
        let enabled = duration > 0 && currentTrack?.canSeek == true
        if slider.isEnabled != enabled { slider.isEnabled = enabled }
        if slider.maxValue != max(1, duration) { slider.maxValue = max(1, duration) }
        if slider.doubleValue != position { slider.doubleValue = position }
        updateTimeLabels(position: position, duration: duration)
    }

    private func updateTimeLabels(position: TimeInterval, duration: TimeInterval) {
        let elapsed = formatTime(position)
        let remaining = "-" + formatTime(max(0, duration - position))
        if elapsedLabel.stringValue != elapsed { elapsedLabel.stringValue = elapsed }
        if remainingLabel.stringValue != remaining { remainingLabel.stringValue = remaining }
    }

    private func updateTimeLabelEmphasis(_ emphasis: CGFloat) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = NSColor.labelColor.withAlphaComponent(highContrast ? 0.80 : 0.45 + 0.30 * emphasis)
        elapsedLabel.textColor = color
        remainingLabel.textColor = color
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func setArtworkPlaceholder() {
        artworkView.image = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "专辑封面"
        )?.withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        artworkView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.62)
        artworkView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    func setArtwork(_ image: NSImage?) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            setArtworkPlaceholder()
            return
        }
        let size = image.size
        let side = min(size.width, size.height)
        if size.width == size.height {
            artworkView.image = image
        } else {
            // Fill the rounded mask without stretching the art or leaving letterbox edges.
            let crop = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                              width: side, height: side)
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let cropped = cgImage.cropping(to: CGRect(
                   x: crop.minX * CGFloat(cgImage.width) / size.width,
                   y: crop.minY * CGFloat(cgImage.height) / size.height,
                   width: crop.width * CGFloat(cgImage.width) / size.width,
                   height: crop.height * CGFloat(cgImage.height) / size.height
               ).integral) {
                artworkView.image = NSImage(cgImage: cropped, size: crop.size)
            } else {
                artworkView.image = NSImage(size: crop.size, flipped: false) { destination in
                    image.draw(in: destination, from: crop, operation: .sourceOver, fraction: 1)
                    return true
                }
            }
        }
        artworkView.contentTintColor = nil
        artworkView.layer?.backgroundColor = nil
    }

    func resetProgressHover() { slider.resetHover() }

    func discardPendingSeek() {
        pendingSeek = nil
        updateProgress()
    }

    @objc private func openMusic(_ sender: Any?) {
        onOpenMusic?()
    }

    @objc private func seek(_ sender: MenuProgressSlider) {
        guard sender.canSeekCurrentTrack, let track = currentTrack, track.canSeek, track.duration > 0 else { return }
        let target = min(track.duration, max(0, sender.doubleValue))
        updateTimeLabels(position: target, duration: track.duration)
        guard !sender.isTracking, let onSeek else { return }
        pendingSeek = (target, CACurrentMediaTime() + 3.5)
        onSeek(target)
    }
}

// MARK: - Smooth menu bar karaoke

private final class KaraokeStatusTitleView: NSView {
    var renderingVisible = true {
        didSet {
            if !renderingVisible { stopTimer() }
        }
    }
    private struct TimedGlyph {
        let start: TimeInterval
        let end: TimeInterval
        let offset: CGFloat
        let width: CGFloat
    }

    private struct Segment {
        let range: NSRange
        let start: TimeInterval
        let end: TimeInterval
        let offset: CGFloat
        let width: CGFloat
        let glyphs: [TimedGlyph]
    }

    private struct LineInk {
        struct Rasterized {
            let image: CGImage
            let pointSize: CGSize
        }

        let upcoming: NSAttributedString
        let sung: NSAttributedString
        let upcomingRaster: Rasterized?
        let sungRaster: Rasterized?

        static let padding: CGFloat = 4

        func draw(at origin: NSPoint, highlighted: Bool, in context: CGContext) {
            if let raster = highlighted ? sungRaster : upcomingRaster {
                let dest = CGRect(
                    x: origin.x - Self.padding,
                    y: origin.y - Self.padding,
                    width: raster.pointSize.width,
                    height: raster.pointSize.height
                )
                context.saveGState()
                if NSGraphicsContext.current?.isFlipped == true {
                    context.translateBy(x: dest.minX, y: dest.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(raster.image, in: CGRect(origin: .zero, size: dest.size))
                } else {
                    context.draw(raster.image, in: dest)
                }
                context.restoreGState()
            } else {
                (highlighted ? sung : upcoming).draw(at: origin)
            }
        }
    }

    private struct MonotonicBounds {
        let hasBase: Bool
        let baseMinX: CGFloat
        let baseMaxX: CGFloat
        let hasSung: Bool
        let sungMaxX: CGFloat
    }

    private struct DrawnFrameKey: Equatable {
        let originPx: Int
        let sungPx: Int
        let alphaBucket: Int
        let lineID: String?
        let nonMonotonic: Bool
    }

    private static let lineTransitionDuration: CFTimeInterval = 0.16
    private let font = NSFont.menuBarFont(ofSize: 0)
    private var displayText = ""
    private var displaySize = NSSize.zero
    private var segments: [Segment] = []
    private var isMonotonicLTR = false
    private var animationEnd: TimeInterval = -.infinity
    private var basePosition: TimeInterval = 0
    private var positionRate = 1.0
    private var sampledAt: CFTimeInterval = 0
    private var isPlaying = false
    private var displayTimer: Timer?
    private var wordWakeTimer: Timer?
    private var currentLineID: String?
    private var renderedOriginX: CGFloat?
    private var lastDrawTime: CFTimeInterval = 0
    private var lineTransitionStartedAt: CFTimeInterval?
    private var renderedLine: LyricLine?
    private var activeColor = AppPreferences.menuBarLyricsActiveColor
    private var inactiveColor = AppPreferences.menuBarLyricsInactiveColor
    private var lineInk: [String: LineInk] = [:]
    private var inkScale: CGFloat = 0
    private var inkUsesHighContrast = false
    private var lastDrawnKey: DrawnFrameKey?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        displayTimer?.invalidate()
        wordWakeTimer?.invalidate()
    }

    func update(line: LyricLine, position: TimeInterval, isPlaying: Bool,
                positionSampledAt: CFTimeInterval? = nil, positionRate: Double = 1) {
        let now = positionSampledAt ?? CACurrentMediaTime()
        let estimated = interpolatedPosition(at: now)
        let lineChanged = renderedLine != line
        let playbackChanged = self.isPlaying != isPlaying
        if currentLineID != line.id {
            if currentLineID != nil,
               !displayText.isEmpty,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                lineTransitionStartedAt = now
            } else {
                lineTransitionStartedAt = nil
            }
            currentLineID = line.id
            renderedOriginX = nil
            lastDrawTime = now
        }
        let error = position - estimated
        if positionSampledAt == nil, self.isPlaying, isPlaying, abs(error) < 0.75 {
            // Small sample corrections should not become visible motion.
            basePosition = estimated + error * 0.06
        } else {
            basePosition = position
        }
        sampledAt = now
        self.positionRate = positionRate
        self.isPlaying = isPlaying

        if lineChanged {
            rebuildDisplay(line: line)
            renderedLine = line
        }
        let wasAnimating = displayTimer != nil
        let animating = needsAnimatedRefresh(at: now)
        if animating {
            activateTimer()
        } else {
            stopTimer()
        }
        if lineChanged || playbackChanged || (wasAnimating && !animating)
            || (!animating && position != estimated && min(position, estimated) < animationEnd) {
            needsDisplay = true
        }
    }

    func deactivate() {
        if !displayText.isEmpty { needsDisplay = true }
        isPlaying = false
        stopTimer()
        displayText = ""
        displaySize = .zero
        segments = []
        isMonotonicLTR = false
        animationEnd = -.infinity
        currentLineID = nil
        renderedLine = nil
        renderedOriginX = nil
        lineTransitionStartedAt = nil
        lineInk.removeAll()
        lastDrawnKey = nil
    }

    func reloadColors() {
        activeColor = AppPreferences.menuBarLyricsActiveColor
        inactiveColor = AppPreferences.menuBarLyricsInactiveColor
        lineInk.removeAll()
        lastDrawnKey = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineInk.removeAll()
        lastDrawnKey = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard !displayText.isEmpty else {
            lastDrawnKey = nil
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if scale != inkScale || highContrast != inkUsesHighContrast {
            inkScale = scale
            inkUsesHighContrast = highContrast
            lineInk.removeAll()
            lastDrawnKey = nil
        }

        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        let targetOriginX = horizontalOrigin(
            textWidth: displaySize.width,
            position: position,
            segments: segments
        )
        let originX = smoothedOrigin(target: targetOriginX, at: now)
        let origin = NSPoint(
            x: originX,
            y: floor((bounds.height - displaySize.height) / 2)
        )

        var alpha: CGFloat = 1
        if let startedAt = lineTransitionStartedAt {
            let progress = min(1, max(0, (now - startedAt) / Self.lineTransitionDuration))
            alpha = 1 - 0.4 * (1 - progress) * (1 - progress)
            if progress == 1 { lineTransitionStartedAt = nil }
        }
        let monotonicBounds = isMonotonicLTR ? monotonicBounds(at: position, originX: originX) : nil
        lastDrawnKey = drawnKey(
            originX: originX,
            alpha: alpha,
            scale: scale,
            position: position,
            monotonicBounds: monotonicBounds
        )
        drawLine(
            text: displayText,
            segments: segments,
            position: position,
            origin: origin,
            alpha: alpha,
            monotonicBounds: monotonicBounds
        )
        if !needsAnimatedRefresh(at: now) { stopTimer() }
    }

    private func drawLine(
        text: String,
        segments: [Segment],
        position: TimeInterval,
        origin: NSPoint,
        alpha: CGFloat,
        monotonicBounds: MonotonicBounds? = nil
    ) {
        guard alpha > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        let ink = ink(for: text)

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        guard segments.contains(where: { !$0.glyphs.isEmpty }) else {
            ink.draw(at: origin, highlighted: false, in: context)
            return
        }

        if let boundsInfo = monotonicBounds ?? (isMonotonicLTR ? self.monotonicBounds(at: position, originX: origin.x) : nil) {
            if boundsInfo.hasBase {
                let baseRect = CGRect(
                    x: boundsInfo.baseMinX,
                    y: origin.y,
                    width: max(0, boundsInfo.baseMaxX - boundsInfo.baseMinX),
                    height: bounds.height
                ).intersection(bounds)
                if !baseRect.isEmpty {
                    context.saveGState()
                    context.clip(to: baseRect)
                    ink.draw(at: origin, highlighted: false, in: context)
                    context.restoreGState()
                }
            }
            if boundsInfo.hasSung {
                let sungRect = CGRect(
                    x: boundsInfo.baseMinX,
                    y: origin.y,
                    width: max(0, boundsInfo.sungMaxX - boundsInfo.baseMinX),
                    height: bounds.height
                ).intersection(bounds)
                if !sungRect.isEmpty {
                    context.clip(to: sungRect)
                    ink.draw(at: origin, highlighted: true, in: context)
                }
            }
            return
        }

        let baseClip = CGMutablePath()
        let sungClip = CGMutablePath()
        func addUnit(offset: CGFloat, width: CGFloat, fraction: Double) {
            let x = origin.x + offset
            guard width > 0, x + width >= 0, x <= bounds.width else { return }
            let rect = CGRect(x: x, y: origin.y, width: width, height: bounds.height)
            baseClip.addRect(rect)
            if fraction > 0 {
                sungClip.addRect(CGRect(x: x, y: rect.minY, width: width * fraction, height: rect.height))
            }
        }

        for segment in segments {
            if segment.glyphs.isEmpty {
                let duration = max(0.01, segment.end - segment.start)
                let fraction = min(1, max(0, (position - segment.start) / duration))
                addUnit(offset: segment.offset, width: segment.width, fraction: fraction)
                continue
            }

            for glyph in segment.glyphs {
                let duration = max(0.01, glyph.end - glyph.start)
                let fraction = min(1, max(0, (position - glyph.start) / duration))
                addUnit(offset: glyph.offset, width: glyph.width, fraction: fraction)
            }
        }
        // Paint each color once using the same time-based clipping intervals.
        if !baseClip.isEmpty {
            context.saveGState()
            context.addPath(baseClip)
            context.clip()
            ink.draw(at: origin, highlighted: false, in: context)
            context.restoreGState()
        }
        if !sungClip.isEmpty {
            context.addPath(sungClip)
            context.clip()
            ink.draw(at: origin, highlighted: true, in: context)
        }
    }

    private func ink(for text: String) -> LineInk {
        if let cached = lineInk[text] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        // The cached bitmap must use the status item's appearance, which can differ from the app's.
        var baseColor = inactiveColor
        var sungColor = activeColor
        effectiveAppearance.lyricsAppearance.performAsCurrentDrawingAppearance {
            baseColor = inactiveColor.usingColorSpace(.sRGB) ?? inactiveColor
            sungColor = activeColor.usingColorSpace(.sRGB) ?? activeColor
        }
        if inkUsesHighContrast {
            baseColor = baseColor.withAlphaComponent(max(0.72, baseColor.alphaComponent))
        }
        let upcoming = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: baseColor, .paragraphStyle: paragraph
        ])
        let sung = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: sungColor, .paragraphStyle: paragraph
        ])
        let result = LineInk(upcoming: upcoming, sung: sung, upcomingRaster: rasterize(upcoming), sungRaster: rasterize(sung))
        lineInk[text] = result
        return result
    }

    private func rasterize(_ text: NSAttributedString) -> LineInk.Rasterized? {
        let size = text.size()
        let padding = LineInk.padding
        let width = Int(ceil((size.width + 2 * padding) * inkScale))
        let height = Int(ceil((size.height + 2 * padding) * inkScale))
        // Very long lines still draw normally if an offscreen bitmap would be too large.
        guard width > 0, width <= 8192, height > 0, height <= 512,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: inkScale, y: -inkScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        text.draw(at: NSPoint(x: padding, y: padding))
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = bitmap.makeImage() else { return nil }
        return LineInk.Rasterized(
            image: rendered,
            pointSize: CGSize(width: CGFloat(width) / inkScale, height: CGFloat(height) / inkScale)
        )
    }

    private func horizontalOrigin(
        textWidth: CGFloat,
        position: TimeInterval,
        segments: [Segment]
    ) -> CGFloat {
        let padding: CGFloat = 7
        guard textWidth > bounds.width - padding * 2 else {
            return floor((bounds.width - textWidth) / 2)
        }

        var cursor: CGFloat = 0
        for segment in segments {
            if position < segment.start {
                cursor = segment.offset
                break
            }
            if position < segment.end {
                let fraction = (position - segment.start) / max(0.01, segment.end - segment.start)
                cursor = segment.offset + segment.width * fraction
                break
            }
            cursor = segment.offset + segment.width
        }

        let desired = bounds.width * 0.56 - cursor
        let minimum = bounds.width - padding - textWidth
        return floor(min(padding, max(minimum, desired)))
    }

    private func computeSmoothedOrigin(target: CGFloat, at now: CFTimeInterval) -> CGFloat {
        if !AppPreferences.smoothScrolling || !isPlaying {
            return target
        }
        guard let renderedOriginX else {
            return target
        }
        let elapsed = min(0.05, max(1.0 / 240.0, now - lastDrawTime))
        let blend = 1 - exp(-elapsed / 0.09)
        let interpolated = renderedOriginX + (target - renderedOriginX) * blend
        return abs(interpolated - target) <= 0.1 ? target : interpolated
    }

    private func smoothedOrigin(target: CGFloat, at now: CFTimeInterval) -> CGFloat {
        let next = computeSmoothedOrigin(target: target, at: now)
        renderedOriginX = next
        lastDrawTime = now
        return next
    }

    private func rebuildDisplay(line: LyricLine) {
        lastDrawnKey = nil
        let result = NSMutableString()
        var rebuilt: [Segment] = []
        for word in line.words {
            let location = result.length
            result.append(word.text)
            rebuilt.append(Segment(range: NSRange(location: location, length: (word.text as NSString).length),
                                   start: word.start, end: word.end, offset: 0, width: 0, glyphs: []))
        }
        if line.words.isEmpty { result.append(line.text) }
        displayText = result as String
        lineInk = lineInk.filter { $0.key == displayText }
        let metrics = NSAttributedString(
            string: displayText,
            attributes: [.font: font]
        )
        displaySize = metrics.size()
        let ctLine = CTLineCreateWithAttributedString(metrics)
        segments = rebuilt.map { segment in
            let startX = CTLineGetOffsetForStringIndex(ctLine, segment.range.location, nil)
            let endX = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(segment.range), nil)
            let offset = min(startX, endX)
            let width = abs(endX - startX)
            return Segment(
                range: segment.range,
                start: segment.start,
                end: segment.end,
                offset: offset,
                width: width,
                glyphs: timedGlyphs(
                    in: segment.range,
                    ctLine: ctLine,
                    start: segment.start,
                    end: segment.end,
                    totalWidth: width
                )
            )
        }
        var monotonic = true
        var lastOffset: CGFloat = 0
        var lastTime = -Double.infinity
        for segment in segments {
            if segment.glyphs.isEmpty {
                if segment.width > 0 {
                    if segment.offset < lastOffset - 0.5 || segment.start < lastTime - 0.001 || segment.end < segment.start {
                        monotonic = false
                        break
                    }
                    lastOffset = segment.offset + segment.width
                    lastTime = segment.end
                }
            } else {
                for glyph in segment.glyphs {
                    if glyph.offset < lastOffset - 0.5 || glyph.start < lastTime - 0.001 || glyph.end < glyph.start {
                        monotonic = false
                        break
                    }
                    lastOffset = glyph.offset + glyph.width
                    lastTime = glyph.end
                }
                if !monotonic { break }
            }
        }
        isMonotonicLTR = monotonic
        animationEnd = segments.reduce(-Double.infinity) { end, segment in
            segment.glyphs.reduce(max(end, max(segment.end, segment.start + 0.01))) { end, glyph in
                max(end, max(glyph.end, glyph.start + 0.01))
            }
        }
    }

    private func timedGlyphs(
        in range: NSRange,
        ctLine: CTLine,
        start: TimeInterval,
        end: TimeInterval,
        totalWidth: CGFloat
    ) -> [TimedGlyph] {
        guard totalWidth > 0,
              let stringRange = Range(range, in: displayText) else { return [] }

        var ranges: [NSRange] = []
        displayText.enumerateSubstrings(
            in: stringRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            ranges.append(NSRange(substringRange, in: self.displayText))
        }

        let duration = max(0.01, end - start)
        var consumedWidth: CGFloat = 0
        return ranges.compactMap { glyphRange in
            let startX = CTLineGetOffsetForStringIndex(ctLine, glyphRange.location, nil)
            let endX = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(glyphRange), nil)
            let offset = min(startX, endX)
            let width = abs(endX - startX)
            guard width > 0 else { return nil }
            let glyphStart = start + duration * TimeInterval(consumedWidth / totalWidth)
            consumedWidth += width
            let glyphEnd = start + duration * TimeInterval(consumedWidth / totalWidth)
            return TimedGlyph(
                start: glyphStart,
                end: glyphEnd,
                offset: offset,
                width: width
            )
        }
    }

    private func needsAnimatedRefresh(at now: CFTimeInterval) -> Bool {
        if let startedAt = lineTransitionStartedAt, now - startedAt < Self.lineTransitionDuration { return true }
        guard isPlaying else { return false }
        let position = interpolatedPosition(at: now)
        if position < animationEnd { return true }
        guard let renderedOriginX else { return false }
        return renderedOriginX != horizontalOrigin(
            textWidth: displaySize.width, position: position, segments: segments
        )
    }

    private func monotonicBounds(at position: TimeInterval, originX: CGFloat) -> MonotonicBounds {
        var baseMinX = CGFloat.greatestFiniteMagnitude
        var baseMaxX = -CGFloat.greatestFiniteMagnitude
        var sungMaxX = -CGFloat.greatestFiniteMagnitude
        var hasBase = false
        var hasSung = false

        for segment in segments {
            if segment.glyphs.isEmpty {
                let x = originX + segment.offset
                guard segment.width > 0, x + segment.width >= 0, x <= bounds.width else { continue }
                hasBase = true
                baseMinX = min(baseMinX, x)
                baseMaxX = max(baseMaxX, x + segment.width)
                if position > segment.start {
                    let duration = max(0.01, segment.end - segment.start)
                    let fraction = min(1, max(0, (position - segment.start) / duration))
                    if fraction > 0 {
                        hasSung = true
                        sungMaxX = max(sungMaxX, x + segment.width * fraction)
                    }
                }
                continue
            }
            for glyph in segment.glyphs {
                let x = originX + glyph.offset
                guard glyph.width > 0, x + glyph.width >= 0, x <= bounds.width else { continue }
                hasBase = true
                baseMinX = min(baseMinX, x)
                baseMaxX = max(baseMaxX, x + glyph.width)
                if position > glyph.start {
                    let duration = max(0.01, glyph.end - glyph.start)
                    let fraction = min(1, max(0, (position - glyph.start) / duration))
                    if fraction > 0 {
                        hasSung = true
                        sungMaxX = max(sungMaxX, x + glyph.width * fraction)
                    }
                }
            }
        }
        return MonotonicBounds(
            hasBase: hasBase,
            baseMinX: baseMinX,
            baseMaxX: baseMaxX,
            hasSung: hasSung,
            sungMaxX: sungMaxX
        )
    }

    private func drawnKey(
        originX: CGFloat,
        alpha: CGFloat,
        scale: CGFloat,
        position: TimeInterval,
        monotonicBounds: MonotonicBounds?
    ) -> DrawnFrameKey {
        let originPx = Int((originX * scale).rounded())
        let alphaBucket = Int((alpha * 100).rounded())
        let sungPx: Int
        if let monotonicBounds {
            sungPx = monotonicBounds.hasSung ? Int((monotonicBounds.sungMaxX * scale).rounded()) : Int.min
        } else if !segments.contains(where: { !$0.glyphs.isEmpty }) {
            sungPx = Int.min
        } else {
            return DrawnFrameKey(
                originPx: originPx,
                sungPx: Int((position * 60).rounded()),
                alphaBucket: alphaBucket,
                lineID: currentLineID,
                nonMonotonic: true
            )
        }
        return DrawnFrameKey(
            originPx: originPx,
            sungPx: sungPx,
            alphaBucket: alphaBucket,
            lineID: currentLineID,
            nonMonotonic: false
        )
    }

    private func hasActiveWord(at position: TimeInterval) -> Bool {
        for segment in segments {
            if segment.glyphs.isEmpty {
                if segment.width > 0, position >= segment.start, position < segment.end { return true }
            } else {
                for glyph in segment.glyphs where glyph.width > 0 {
                    if position >= glyph.start, position < glyph.end { return true }
                }
            }
        }
        return false
    }

    private func nextWordStart(after position: TimeInterval) -> TimeInterval? {
        var next: TimeInterval?
        for segment in segments {
            if segment.glyphs.isEmpty {
                if segment.width > 0, segment.start > position {
                    next = next.map { min($0, segment.start) } ?? segment.start
                }
            } else {
                for glyph in segment.glyphs where glyph.width > 0 && glyph.start > position {
                    next = next.map { min($0, glyph.start) } ?? glyph.start
                }
            }
        }
        return next
    }

    private func tickDisplayTimer() {
        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        guard needsAnimatedRefresh(at: now) else {
            stopTimer()
            needsDisplay = true
            return
        }

        let targetOriginX = horizontalOrigin(
            textWidth: displaySize.width,
            position: position,
            segments: segments
        )
        let nextOriginX = computeSmoothedOrigin(target: targetOriginX, at: now)
        let alpha: CGFloat
        if let startedAt = lineTransitionStartedAt {
            let progress = min(1, max(0, (now - startedAt) / Self.lineTransitionDuration))
            alpha = 1 - 0.4 * (1 - progress) * (1 - progress)
        } else {
            alpha = 1
        }
        let scale = window?.backingScaleFactor ?? 2
        let monotonic = isMonotonicLTR ? monotonicBounds(at: position, originX: nextOriginX) : nil
        let key = drawnKey(
            originX: nextOriginX,
            alpha: alpha,
            scale: scale,
            position: position,
            monotonicBounds: monotonic
        )
        if key != lastDrawnKey {
            needsDisplay = true
            return
        }

        if lineTransitionStartedAt == nil,
           abs(nextOriginX - targetOriginX) <= 0.1,
           !hasActiveWord(at: position),
           let wakeAt = nextWordStart(after: position) {
            let delay = max(0.01, (wakeAt - position) / max(0.25, positionRate))
            displayTimer?.invalidate()
            displayTimer = nil
            wordWakeTimer?.invalidate()
            let wakeTimer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.wordWakeTimer = nil
                self.activateTimer()
                self.tickDisplayTimer()
            }
            wakeTimer.tolerance = min(0.02, delay * 0.1)
            wordWakeTimer = wakeTimer
            RunLoop.main.add(wakeTimer, forMode: .common)
        }
    }

    private func activateTimer() {
        guard renderingVisible, displayTimer == nil else { return }
        wordWakeTimer?.invalidate()
        wordWakeTimer = nil
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 20.0 : 1.0 / 30.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickDisplayTimer()
        }
        timer.tolerance = 0.01
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        wordWakeTimer?.invalidate()
        wordWakeTimer = nil
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        basePosition + (isPlaying ? max(0, now - sampledAt) * positionRate : 0)
    }
}
