import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    private enum LyricsTitle {
        case text(String)
        case synced(TrackInfo, LyricsDocument, sampledAt: CFTimeInterval)
    }

    private static let footerHeight: CGFloat = 46
    // The menu bar inserts new items to the left of existing ones.
    private let nextStatusItem = MenuBarController.makeStatusItem("Playback.Next", length: 26)
    private let toggleStatusItem = MenuBarController.makeStatusItem("Playback.Toggle", length: 26)
    private let previousStatusItem = MenuBarController.makeStatusItem("Playback.Previous", length: 26)
    private let statusItem = MenuBarController.makeStatusItem("Lyrics", length: 180)
    private var playbackStatusItems: [NSStatusItem] { [previousStatusItem, toggleStatusItem, nextStatusItem] }
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
    private var playerMessage = "打开音乐 App，开始播放"
    private var playerArtwork: NSImage?
    private var playerArtworkNeedsUpdate = true
    private var latestTitle = LyricsTitle.text("♫ 歌词")
    private var floatingLyricsVisible: Bool
    private var lyricsItemWidth: CGFloat = 180
    private var lyricsVisibility: CGFloat
    private var visibilityTimer: Timer?
    private var lastControlState: PlayerState?
    private var localDismissMonitor: Any?
    private var outsideDismissMonitor: Any?
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
        configurePlaybackItem(previousStatusItem, symbol: "backward.fill", label: "上一首", action: #selector(playPrevious))
        configurePlaybackItem(toggleStatusItem, symbol: "play.fill", label: "播放", action: #selector(togglePlayback))
        configurePlaybackItem(nextStatusItem, symbol: "forward.fill", label: "下一首", action: #selector(playNext))
        configureStatusItem()
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
        playerPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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

    private func updatePlayer(track: TrackInfo?, message: String = "打开音乐 App，开始播放") {
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
        case .loadingLyrics(let track), .noLyrics(let track):
            updatePlayer(track: track)
            updateTitle(.text(track.title))
        case .error:
            updatePlayer(track: nil, message: "请检查设置中的诊断信息")
            updateTitle(.text("音乐连接中断"))
        case .idle, .stopped, .musicNotRunning:
            updatePlayer(track: nil)
            updateTitle(.text("♫ 歌词"))
        }
    }

    private func updateControls(_ track: TrackInfo?) {
        guard lastControlState != track?.state else { return }
        lastControlState = track?.state
        updatePlaybackItems()
        if let button = toggleStatusItem.button {
            let playing = track?.state == .playing
            setPlaybackIcon(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", on: button)
        }
    }

    private func configurePlaybackItem(_ item: NSStatusItem, symbol: String, label: String, action: Selector) {
        guard let button = item.button else { return }
        button.target = self
        button.action = action
        button.isEnabled = false
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setPlaybackIcon(symbol, label: label, on: button)
    }

    private func setPlaybackIcon(_ symbol: String, label: String, on button: NSStatusBarButton) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "\(label) · 按住 Option 点击打开播放器"
        button.setAccessibilityLabel(label)
    }

    private func updatePlaybackItems() {
        let show = floatingLyricsVisible || AppPreferences.statusBarMode != .icon
        let canPlay = lastControlState != nil
        for item in playbackStatusItems {
            if item.isVisible != show { item.isVisible = show }
            item.button?.isEnabled = canPlay || floatingLyricsVisible
            item.button?.appearsDisabled = !canPlay && floatingLyricsVisible
        }
    }

    @objc private func playPrevious(_ sender: NSStatusBarButton) {
        performPlaybackAction(onPreviousTrack, from: sender)
    }

    @objc private func togglePlayback(_ sender: NSStatusBarButton) {
        performPlaybackAction(onTogglePlayPause, from: sender)
    }

    @objc private func playNext(_ sender: NSStatusBarButton) {
        performPlaybackAction(onNextTrack, from: sender)
    }

    private func performPlaybackAction(_ action: (() -> Void)?, from sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondaryClick = event?.type == .rightMouseUp && sender.window != nil && event?.window === sender.window
        if secondaryClick || NSEvent.modifierFlags.contains(.option) {
            statusButtonClicked(sender)
            return
        }
        guard lastControlState != nil else { return }
        dismissPlayer()
        action?()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: .leftMouseUp)
        statusView.wantsLayer = true
        statusView.layer?.masksToBounds = true
        button.addSubview(statusView)
        statusView.addSubview(lyricButton)
        lyricButton.font = .menuBarFont(ofSize: 0)
        lyricButton.layer?.masksToBounds = true
        karaokeTitleView.wantsLayer = true
        lyricButton.addSubview(karaokeTitleView)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reloadAppearance()
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
                  !playbackStatusItems.contains(where: { $0.button?.window === window }) else { return }
        }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        // The system can report status-item clicks without our status window.
        let inMenuBar = NSScreen.screens.contains { screen in
            let menuBarHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            return screen.frame.contains(point) && point.y >= screen.frame.maxY - menuBarHeight
        }
        if !inMenuBar { dismissPlayer() }
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
        if !visible { displayLatestTitle() }

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
        if !statusItem.isVisible { statusItem.isVisible = true }
    }

    @objc private func screenParametersChanged() {
        dismissPlayer()
        reloadAppearance()
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
    }

    deinit {
        visibilityTimer?.invalidate()
        removeDismissMonitors()
        NotificationCenter.default.removeObserver(self)
        for item in playbackStatusItems + [statusItem] {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func updateTitle(_ title: LyricsTitle) {
        latestTitle = title
        if !floatingLyricsVisible && AppPreferences.statusBarMode != .icon {
            displayLatestTitle()
        }
    }

    private func displayLatestTitle() {
        if AppPreferences.statusBarMode == .icon {
            karaokeTitleView.deactivate()
            karaokeTitleView.isHidden = true
            lyricButton.setSymbol("music.note", label: "打开播放器")
            statusItem.button?.setAccessibilityLabel("打开播放器")
            return
        }
        if lyricButton.image != nil {
            lyricButton.image = nil
            lyricButton.imagePosition = .noImage
        }
        switch latestTitle {
        case .text(let text):
            setTitle(text)
        case .synced(let track, let lyrics, let sampledAt):
            let elapsed = track.state == .playing ? min(0.5, CACurrentMediaTime() - sampledAt) : 0
            let position = track.position + elapsed
            if let line = lyrics.line(at: position) {
                setKaraokeTitle(line: line, position: position, isPlaying: track.state == .playing)
            } else {
                setTitle(track.title)
            }
        }
    }

    private func setTitle(_ title: String) {
        karaokeTitleView.deactivate()
        karaokeTitleView.isHidden = true
        lyricButton.title = title
        statusItem.button?.setAccessibilityLabel("打开播放器，" + title)
    }

    private func setKaraokeTitle(line: LyricLine, position: TimeInterval, isPlaying: Bool) {
        if !lyricButton.title.isEmpty { lyricButton.title = "" }
        let label = "打开播放器，" + line.text
        if let button = statusItem.button, button.accessibilityLabel() != label {
            button.setAccessibilityLabel(label)
        }
        karaokeTitleView.update(line: line, position: position, isPlaying: isPlaying)
        karaokeTitleView.isHidden = false
    }

}

private final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class StatusItemContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    static let horizontalInset: CGFloat = 16
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
        artworkView.layer?.cornerRadius = 10
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
            view.toolTip = "打开 Apple Music"
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("打开 Apple Music")
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
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            artworkView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            slider.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: Self.horizontalInset),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            slider.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            slider.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: 6),
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
            if previousTrack != nil { titleLabel.stringValue = "播放器" }
            let subtitle = message ?? "未播放歌曲"
            if subtitleLabel.stringValue != subtitle { subtitleLabel.stringValue = subtitle }
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
        let enabled = duration > 0
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
            artworkView.image = NSImage(size: crop.size, flipped: false) { destination in
                image.draw(in: destination, from: crop, operation: .sourceOver, fraction: 1)
                return true
            }
        }
        artworkView.contentTintColor = nil
        artworkView.layer?.backgroundColor = nil
    }

    func resetProgressHover() { slider.resetHover() }

    @objc private func openMusic(_ sender: Any?) {
        onOpenMusic?()
    }

    @objc private func seek(_ sender: MenuProgressSlider) {
        guard sender.canSeekCurrentTrack, let track = currentTrack, track.duration > 0 else { return }
        let target = min(track.duration, max(0, sender.doubleValue))
        updateTimeLabels(position: target, duration: track.duration)
        guard !sender.isTracking, let onSeek else { return }
        pendingSeek = (target, CACurrentMediaTime() + 3.5)
        onSeek(target)
    }
}

// MARK: - Smooth menu bar karaoke

private final class KaraokeStatusTitleView: NSView {
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
        let upcoming: NSAttributedString
        let sung: NSAttributedString
        let upcomingImage: NSImage?
        let sungImage: NSImage?

        static let padding: CGFloat = 4

        func draw(at origin: NSPoint, highlighted: Bool) {
            if let image = highlighted ? sungImage : upcomingImage {
                image.draw(
                    in: NSRect(origin: NSPoint(x: origin.x - Self.padding, y: origin.y - Self.padding),
                               size: image.size),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                )
            } else {
                (highlighted ? sung : upcoming).draw(at: origin)
            }
        }
    }

    private static let lineTransitionDuration: CFTimeInterval = 0.16
    private let font = NSFont.menuBarFont(ofSize: 0)
    private var displayText = ""
    private var displaySize = NSSize.zero
    private var segments: [Segment] = []
    private var animationEnd: TimeInterval = -.infinity
    private var prefixLength = 0
    private var basePosition: TimeInterval = 0
    private var sampledAt: CFTimeInterval = 0
    private var isPlaying = false
    private var displayTimer: Timer?
    private var currentLineID: String?
    private var renderedOriginX: CGFloat?
    private var lastDrawTime: CFTimeInterval = 0
    private var prefixWidth: CGFloat = 0
    private var lineTransitionStartedAt: CFTimeInterval?
    private var renderedLine: LyricLine?
    private var activeColor = AppPreferences.menuBarLyricsActiveColor
    private var inactiveColor = AppPreferences.menuBarLyricsInactiveColor
    private var lineInk: [String: LineInk] = [:]
    private var inkScale: CGFloat = 0
    private var inkUsesHighContrast = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        displayTimer?.invalidate()
    }

    func update(line: LyricLine, position: TimeInterval, isPlaying: Bool) {
        let now = CACurrentMediaTime()
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
        if self.isPlaying, isPlaying, abs(error) < 0.75 {
            // Small sample corrections should not become visible motion.
            basePosition = estimated + error * 0.06
        } else {
            basePosition = position
        }
        sampledAt = now
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
        animationEnd = -.infinity
        currentLineID = nil
        renderedLine = nil
        renderedOriginX = nil
        lineTransitionStartedAt = nil
        lineInk.removeAll()
    }

    func reloadColors() {
        activeColor = AppPreferences.menuBarLyricsActiveColor
        inactiveColor = AppPreferences.menuBarLyricsInactiveColor
        lineInk.removeAll()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineInk.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard !displayText.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if scale != inkScale || highContrast != inkUsesHighContrast {
            inkScale = scale
            inkUsesHighContrast = highContrast
            lineInk.removeAll()
        }

        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        let targetOriginX = horizontalOrigin(
            textWidth: displaySize.width,
            position: position,
            segments: segments,
            prefixWidth: prefixWidth
        )
        let origin = NSPoint(
            x: smoothedOrigin(target: targetOriginX, at: now),
            y: floor((bounds.height - displaySize.height) / 2)
        )

        var alpha: CGFloat = 1
        if let startedAt = lineTransitionStartedAt {
            let progress = min(1, max(0, (now - startedAt) / Self.lineTransitionDuration))
            alpha = 1 - 0.4 * (1 - progress) * (1 - progress)
            if progress == 1 { lineTransitionStartedAt = nil }
        }
        drawLine(
            text: displayText,
            segments: segments,
            prefixLength: prefixLength,
            prefixWidth: prefixWidth,
            position: position,
            origin: origin,
            alpha: alpha
        )
        if !needsAnimatedRefresh(at: now) { stopTimer() }
    }

    private func drawLine(
        text: String,
        segments: [Segment],
        prefixLength: Int,
        prefixWidth: CGFloat,
        position: TimeInterval,
        origin: NSPoint,
        alpha: CGFloat
    ) {
        guard alpha > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        let ink = ink(for: text)

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        guard segments.contains(where: { !$0.glyphs.isEmpty }) else {
            ink.draw(at: origin, highlighted: false)
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

        if prefixLength > 0 {
            addUnit(offset: 0, width: prefixWidth, fraction: 1)
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
            ink.draw(at: origin, highlighted: false)
            context.restoreGState()
        }
        if !sungClip.isEmpty {
            context.addPath(sungClip)
            context.clip()
            ink.draw(at: origin, highlighted: true)
        }
    }

    private func ink(for text: String) -> LineInk {
        if let cached = lineInk[text] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        // The cached bitmap must use the status item's appearance, which can differ from the app's.
        var baseColor = inactiveColor
        var sungColor = activeColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
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
        let result = LineInk(upcoming: upcoming, sung: sung, upcomingImage: rasterize(upcoming), sungImage: rasterize(sung))
        lineInk[text] = result
        return result
    }

    private func rasterize(_ text: NSAttributedString) -> NSImage? {
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
        let representation = NSBitmapImageRep(cgImage: rendered)
        representation.size = NSSize(width: CGFloat(width) / inkScale, height: CGFloat(height) / inkScale)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private func horizontalOrigin(
        textWidth: CGFloat,
        position: TimeInterval,
        segments: [Segment],
        prefixWidth: CGFloat
    ) -> CGFloat {
        let padding: CGFloat = 7
        guard textWidth > bounds.width - padding * 2 else {
            return floor((bounds.width - textWidth) / 2)
        }

        var cursor = prefixWidth
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

    private func smoothedOrigin(target: CGFloat, at now: CFTimeInterval) -> CGFloat {
        if !AppPreferences.smoothScrolling || !isPlaying {
            renderedOriginX = target
            return target
        }
        guard let renderedOriginX else {
            self.renderedOriginX = target
            lastDrawTime = now
            return target
        }
        let elapsed = min(0.05, max(1.0 / 240.0, now - lastDrawTime))
        let blend = 1 - exp(-elapsed / 0.09)
        let interpolated = renderedOriginX + (target - renderedOriginX) * blend
        let next = abs(interpolated - target) <= 0.1 ? target : interpolated
        self.renderedOriginX = next
        lastDrawTime = now
        return next
    }

    private func rebuildDisplay(line: LyricLine) {
        let prefix = ""
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
        segments = rebuilt.map { segment in
            let prefixRange = NSRange(location: 0, length: segment.range.location)
            let offset = metrics.attributedSubstring(from: prefixRange).size().width
            let width = metrics.attributedSubstring(from: segment.range).size().width
            return Segment(
                range: segment.range,
                start: segment.start,
                end: segment.end,
                offset: offset,
                width: width,
                glyphs: timedGlyphs(
                    in: segment.range,
                    metrics: metrics,
                    start: segment.start,
                    end: segment.end,
                    totalWidth: width
                )
            )
        }
        animationEnd = segments.reduce(-Double.infinity) { end, segment in
            segment.glyphs.reduce(max(end, max(segment.end, segment.start + 0.01))) { end, glyph in
                max(end, max(glyph.end, glyph.start + 0.01))
            }
        }
        prefixLength = (prefix as NSString).length
        prefixWidth = prefixLength > 0
            ? metrics.attributedSubstring(
                from: NSRange(location: 0, length: prefixLength)
            ).size().width
            : 0
    }

    private func timedGlyphs(
        in range: NSRange,
        metrics: NSAttributedString,
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
            let width = metrics.attributedSubstring(from: glyphRange).size().width
            guard width > 0 else { return nil }
            let prefixRange = NSRange(location: 0, length: glyphRange.location)
            let offset = metrics.attributedSubstring(from: prefixRange).size().width
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
            textWidth: displaySize.width, position: position, segments: segments, prefixWidth: prefixWidth
        )
    }

    private func activateTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }
}
