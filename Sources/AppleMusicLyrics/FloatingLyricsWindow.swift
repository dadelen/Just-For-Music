import AppKit
import CoreImage
import QuartzCore
import CoreVideo

final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private static let attentionAnimationKey = "lyricsAttention"
    private static let minimumBackdropOpacityForShadow: CGFloat = 0.15
    private static let occlusionPauseDelay: TimeInterval = 0.55
    private let panel = LyricsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let visibilityFade = PanelFade(usesContentOpacity: true)
    private let canvas = LyricsCanvasView(frame: .zero)
    private let trackDetails = NSView()
    private let title = NSTextField(labelWithString: "桌面歌词")
    private let artist = NSTextField(labelWithString: "")
    private let background = GlassSurface(clearGlass: true, adjustableOpacity: true)
    private let vinyl = VinylPlayerView(frame: .zero)
    private let controls = PlaybackControls(buttonWidth: 36, grouped: true)
    private let closeButton = WindowDotButton(color: .systemRed, symbol: "xmark", label: "关闭歌词窗口")
    private let lockButton = WindowDotButton(color: .systemYellow, symbol: "lock.fill", label: "锁定位置并点击穿透")
    private let modeButton = WindowDotButton(color: .systemGreen, symbol: "arrow.up.left.and.arrow.down.right", label: "选择歌词窗口模式")
    private var windowButtons: [WindowDotButton] { [closeButton, lockButton, modeButton] }
    private lazy var windowButtonPanel = Self.makeControlPanel()
    private lazy var needleButtonPanel = Self.makeControlPanel()
    private lazy var playbackControlsPanel = Self.makeControlPanel()
    private var isPlaybackControlsDetached: Bool { controls.window !== panel && controls.window != nil }

    private static func makeControlPanel() -> NSPanel {
        let child = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        child.isOpaque = false
        child.backgroundColor = .clear
        child.hasShadow = false
        child.hidesOnDeactivate = false
        child.isReleasedWhenClosed = false
        child.isMovable = false
        child.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        return child
    }
    private let modeMenu = NSMenu()
    private var mode = AppPreferences.floatingLyricsMode
    private var vinylSize = AppPreferences.floatingLyricsVinylSize
    private var resizePreviewTimer: Timer?
    private var restoringPosition = true
    private var positionSaveTimer: Timer?
    private var latestStatus: AppStatus = .idle
    private var rendersContent = false
    private var screensAwake = true
    private var pendingOcclusionPause: DispatchWorkItem?
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onVinylTogglePlayPause: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel.isVisible && !visibilityFade.isClosing }
    var showsVinyl: Bool { isVisible && !vinyl.isHidden }

    override init() {
        super.init()
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.contentView = background
        setGlassTransparency(AppPreferences.floatingLyricsGlassTransparency)
        background.content.addSubview(vinyl)
        trackDetails.wantsLayer = true
        trackDetails.layer?.masksToBounds = true
        background.content.addSubview(trackDetails)
        for label in [title, artist] {
            label.lineBreakMode = .byTruncatingTail
            trackDetails.addSubview(label)
        }
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        artist.font = .systemFont(ofSize: 13, weight: .medium)
        background.content.addSubview(canvas)
        background.content.addSubview(controls)
        for button in windowButtons {
            background.content.addSubview(button)
        }
        closeButton.onPress = { [weak self] in self?.setVisible(false) }
        lockButton.onPress = { [weak self] in
            AppPreferences.floatingPositionLocked.toggle()
            self?.applyPositionLock()
        }
        modeButton.onPress = { [weak self] in self?.showModeMenu() }
        for mode in FloatingLyricsMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        vinyl.onTogglePlayPause = { [weak self] in self?.onVinylTogglePlayPause?() }
        controls.onPrevious = { [weak self] in self?.onPreviousTrack?() }
        controls.onToggle = { [weak self] in self?.onTogglePlayPause?() }
        controls.onNext = { [weak self] in self?.onNextTrack?() }
        canvas.onSeek = { [weak self] in self?.onSeek?($0) }
        applyPreferences()
        restorePosition()
        restoringPosition = false
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenPowerChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenPowerChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lowPowerModeChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    deinit {
        positionSaveTimer?.invalidate()
        resizePreviewTimer?.invalidate()
        pendingOcclusionPause?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityChanged() {
        updateBackdropAppearance()
        canvas.invalidateGeometry()
    }

    @objc private func screenChanged() {
        updateSizeLimits()
        constrainToScreen()
        canvas.refreshDisplayLink()
    }

    @objc private func lowPowerModeChanged() {
        DispatchQueue.main.async { [weak self] in self?.canvas.refreshDisplayLink() }
    }

    func resetPlaybackClock() { canvas.resetPlaybackClock() }

    func setMenuBarAppearance(_ appearance: NSAppearance) {
        guard panel.appearance?.name != appearance.name else { return }
        panel.appearance = appearance
        for child in panel.childWindows ?? [] { child.appearance = appearance }
    }

    func reloadLyricsColor() {
        let color = AppPreferences.floatingLyricsTextColor
        title.textColor = color ?? .labelColor
        artist.textColor = color?.withAlphaComponent(0.72) ?? .secondaryLabelColor
        canvas.invalidateGeometry()
    }

    func reloadLyricsFontSize() { canvas.invalidateGeometry() }

    func setGlassTransparency(_ transparency: Double) {
        background.backgroundOpacity = CGFloat(1 - transparency)
        updateBackdropAppearance()
    }

    private var effectiveBackdropOpacity: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : background.backgroundOpacity
    }

    func updateBackdropAppearance() {
        let opacity = effectiveBackdropOpacity
        // With almost no backdrop, the window shadow traces individual glyphs and controls.
        let castsShadow = AppPreferences.floatingLyricsShowsShadow && opacity >= Self.minimumBackdropOpacityForShadow
        if panel.hasShadow != castsShadow {
            panel.hasShadow = castsShadow
        }
        updateFocusOutline(selected: panel.isKeyWindow)
    }

    private func updateFocusOutline(selected: Bool) {
        let width: CGFloat = selected && effectiveBackdropOpacity < Self.minimumBackdropOpacityForShadow ? 1 : 0
        guard let layer = background.layer, layer.borderWidth != width else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = NSColor.systemGray.withAlphaComponent(0.50).cgColor
        layer.borderWidth = width
        CATransaction.commit()
    }

    func applyPreferences() {
        mode = AppPreferences.floatingLyricsMode
        updateSizeLimits()
        applyPositionLock()

        let oldFrame = panel.frame
        let size = mode == .vinyl ? vinylSize : FloatingLyricsMode.minimalSize
        if oldFrame.size != size {
            let origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - size.height)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        vinyl.isHidden = mode == .minimal
        controls.isHidden = mode == .vinyl
        layoutContent()
        updateVinyl()
        updatePlaybackControlsPlacement()
        applyWindowPlacement()
        canvas.setSupplementaryLyrics(showTranslation: AppPreferences.floatingLyricsShowTranslation,
                                      showTransliteration: AppPreferences.floatingLyricsShowTransliteration)
        reloadLyricsColor()
        constrainToScreen()
    }

    private func applyWindowPlacement() {
        let alwaysOnTop = AppPreferences.floatingLyricsShowOverFullScreen
        let level: NSWindow.Level = alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        if AppPreferences.floatingLyricsSpaceBehavior == .currentDesktop {
            behavior.remove(.canJoinAllSpaces)
            behavior.insert(.moveToActiveSpace)
        }
        if alwaysOnTop {
            behavior.insert(.canJoinAllApplications)
        } else {
            behavior.insert(.fullScreenPrimary)
        }
        if panel.isFloatingPanel != alwaysOnTop { panel.isFloatingPanel = alwaysOnTop }
        if panel.level != level { panel.level = level }
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        for child in panel.childWindows ?? [] {
            if child.level != level { child.level = level }
            if child.collectionBehavior != behavior { child.collectionBehavior = behavior }
        }
    }

    private func layoutContent() {
        let frame = panel.contentRect(forFrameRect: panel.frame)
        if mode == .minimal {
            title.alignment = .left
            artist.alignment = .left
            let controlsRect = controlsFrameInContent
            if !isPlaybackControlsDetached {
                controls.frame = controlsRect
            }
            let titleWidth = controlsRect.minX - 36 - 14
            trackDetails.frame = NSRect(x: 36, y: frame.height - 80, width: titleWidth, height: 43)
            title.frame = NSRect(x: 0, y: 19, width: titleWidth, height: 24)
            artist.frame = NSRect(x: 0, y: 0, width: titleWidth, height: 18)
            canvas.frame = NSRect(x: 14, y: 14, width: frame.width - 28, height: frame.height - 102)
        } else {
            let availableHeight = max(1, frame.height - 70)
            let minimum = FloatingLyricsMode.minimumVinylSize
            let legacyLarge = FloatingLyricsMode.maximumVinylSize
            let widthProgress = max(0, (frame.width - minimum.width) / (legacyLarge.width - minimum.width))
            let heightProgress = max(0, (frame.height - minimum.height) / (legacyLarge.height - minimum.height))
            let vinylWidth = min(frame.width * 0.4, 240 + 80 * min(widthProgress, heightProgress))
            let vinylHeight = min(availableHeight, vinylWidth * 1.08 + 26)
            vinyl.frame = NSRect(x: 12, y: 58 + (availableHeight - vinylHeight) / 2,
                                 width: vinylWidth, height: vinylHeight)
            title.alignment = .center
            artist.alignment = .center
            trackDetails.frame = NSRect(x: 22, y: vinyl.frame.minY - 44, width: vinylWidth - 20, height: 40)
            title.frame = NSRect(x: 0, y: 18, width: trackDetails.bounds.width, height: 22)
            artist.frame = NSRect(x: 0, y: 0, width: trackDetails.bounds.width, height: 17)
            canvas.frame = NSRect(x: vinylWidth + 24, y: 14, width: frame.width - vinylWidth - 40, height: frame.height - 28)
        }
        layoutWindowButtons()
        if vinyl.isNeedleButtonDetached { layoutNeedleButtonPanel() }
        if isPlaybackControlsDetached { layoutPlaybackControlsPanel() }
    }

    private func layoutWindowButtons() {
        let height = panel.contentRect(forFrameRect: panel.frame).height
        let buttons = windowButtons.filter { !$0.isHidden }
        let strip = NSRect(x: 10, y: height - 28, width: CGFloat(buttons.count) * 20, height: 23)
        let inChildPanel = closeButton.window !== panel
        if inChildPanel {
            let screenFrame = panel.convertToScreen(background.content.convert(strip, to: nil))
            windowButtonPanel.setFrame(screenFrame, display: true)
        }
        let origin = inChildPanel ? NSPoint.zero : strip.origin
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: origin.x + CGFloat(index) * 20, y: origin.y, width: 20, height: strip.height)
        }
    }

    private func updateWindowButtonPlacement() {
        // WindowServer applies click-through to an entire window. Interactive
        // controls move to small child panels while the lyrics pass clicks through.
        guard !visibilityFade.isClosing else { return }
        if panel.ignoresMouseEvents && panel.isVisible {
            let child = windowButtonPanel
            if closeButton.window === panel, let content = child.contentView {
                child.appearance = panel.appearance
                child.level = panel.level
                child.collectionBehavior = panel.collectionBehavior
                child.alphaValue = panel.alphaValue
                content.alphaValue = background.alphaValue
                for button in windowButtons {
                    button.removeFromSuperview()
                    content.addSubview(button)
                }
                layoutWindowButtons()
            }
            if child.parent !== panel {
                panel.addChildWindow(child, ordered: .above)
            }
        } else if closeButton.window !== panel {
            windowButtonPanel.orderOut(nil)
            for button in windowButtons {
                button.removeFromSuperview()
                background.content.addSubview(button)
                button.resetHover()
            }
            layoutWindowButtons()
        }
        updateNeedleButtonPlacement()
        updatePlaybackControlsPlacement()
    }

    private var controlsFrameInContent: NSRect {
        let frame = panel.contentRect(forFrameRect: panel.frame)
        return NSRect(x: frame.width - 36 - controls.width, y: frame.height - 75,
                      width: controls.width, height: 34)
    }

    private func layoutPlaybackControlsPanel() {
        let strip = controlsFrameInContent
        let screenFrame = panel.convertToScreen(background.content.convert(strip, to: nil)).integral
        if playbackControlsPanel.frame != screenFrame {
            playbackControlsPanel.setFrame(screenFrame, display: true)
        }
        if controls.window === playbackControlsPanel {
            let frame = NSRect(origin: .zero, size: strip.size)
            if controls.frame != frame { controls.frame = frame }
        }
    }

    private func updatePlaybackControlsPlacement() {
        guard !visibilityFade.isClosing else { return }
        let detached = panel.ignoresMouseEvents && panel.isVisible && mode == .minimal
        if detached {
            let child = playbackControlsPanel
            if !isPlaybackControlsDetached, let content = child.contentView {
                child.appearance = panel.appearance
                child.level = panel.level
                child.collectionBehavior = panel.collectionBehavior
                child.alphaValue = panel.alphaValue
                content.alphaValue = background.alphaValue
                content.wantsLayer = true
                controls.removeFromSuperview()
                content.addSubview(controls)
                layoutPlaybackControlsPanel()
            }
            if child.parent !== panel {
                panel.addChildWindow(child, ordered: .above)
            }
        } else if isPlaybackControlsDetached {
            playbackControlsPanel.orderOut(nil)
            controls.removeFromSuperview()
            background.content.addSubview(controls)
            controls.resetHover()
            controls.frame = controlsFrameInContent
        }
    }

    private func layoutNeedleButtonPanel() {
        vinyl.layoutSubtreeIfNeeded()
        let frame = panel.convertToScreen(vinyl.convert(vinyl.needleButtonFrame, to: nil)).integral
        if needleButtonPanel.frame != frame { needleButtonPanel.setFrame(frame, display: true) }
    }

    private func updateNeedleButtonPlacement() {
        guard !visibilityFade.isClosing else { return }
        let detached = panel.ignoresMouseEvents && panel.isVisible && mode == .vinyl && vinyl.allowsPlaybackControl
        if detached, !vinyl.isNeedleButtonDetached, let content = needleButtonPanel.contentView {
            let child = needleButtonPanel
            child.appearance = panel.appearance
            child.level = panel.level
            child.collectionBehavior = panel.collectionBehavior
            child.alphaValue = panel.alphaValue
            content.alphaValue = background.alphaValue
            content.wantsLayer = true
            layoutNeedleButtonPanel()
            vinyl.placeNeedleButton(in: content)
            panel.addChildWindow(child, ordered: .above)
        } else if !detached, vinyl.isNeedleButtonDetached {
            needleButtonPanel.orderOut(nil)
            vinyl.placeNeedleButton(in: vinyl)
        }
    }

    func applyPositionLock() {
        let locked = AppPreferences.floatingPositionLocked
        let resizable = mode == .vinyl && !locked
        if panel.styleMask.contains(.resizable) != resizable {
            if resizable { panel.styleMask.insert(.resizable) }
            else { panel.styleMask.remove(.resizable) }
        }
        panel.isMovable = !locked
        panel.isMovableByWindowBackground = !locked
        if panel.ignoresMouseEvents != locked {
            panel.ignoresMouseEvents = locked
            if locked {
                canvas.setPointerInside(false)
                windowButtons.forEach { $0.resetHover() }
                controls.resetHover()
            }
        }
        lockButton.marked = locked
        let label = locked ? "解锁位置并关闭点击穿透" : "锁定位置并点击穿透"
        lockButton.toolTip = label
        lockButton.setAccessibilityLabel(label)
        updateWindowButtonPlacement()
    }

    private func showModeMenu() {
        for item in modeMenu.items {
            item.state = item.representedObject as? String == mode.rawValue ? .on : .off
        }
        let y = modeButton.isFlipped ? modeButton.bounds.maxY + 4 : modeButton.bounds.minY - 4
        modeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: modeButton)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let selected = FloatingLyricsMode(rawValue: value),
              selected != mode else { return }
        AppPreferences.floatingLyricsMode = selected
        NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
    }

    private func updateVinyl() {
        // Use the same debounced visibility as the lyrics. Brief WindowServer
        // occlusion changes must not interrupt the record's rotation.
        let track = latestStatus.track
        vinyl.allowsPlaybackControl = track != nil
        vinyl.update(playing: track?.state == .playing,
                     visible: panel.isVisible && rendersContent && !vinyl.isHidden,
                     trackIdentity: track?.identityKey,
                     bpm: track?.bpm,
                     position: track?.position, duration: track?.duration)
        updateNeedleButtonPlacement()
    }

    func cueNeedle(ontoRecord: Bool) async { await vinyl.cueNeedle(ontoRecord: ontoRecord) }
    func finishNeedleCue() { vinyl.followPlayback() }

    func showFromPlayer() {
        guard isVisible else {
            setVisible(true)
            return
        }
        panel.orderFrontRegardless()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = background.layer,
              layer.animation(forKey: Self.attentionAnimationKey) == nil else { return }

        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1, 0.984, 1]
        bounce.keyTimes = [0, 0.38, 1]
        bounce.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        bounce.duration = 0.28
        layer.add(bounce, forKey: Self.attentionAnimationKey)
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != isVisible else { return }
        if visible {
            if !panel.isVisible { render(status: latestStatus) }
            visibilityFade.show(panel, animated: animated) {
                panel.orderFrontRegardless()
                updateWindowButtonPlacement()
            }
            updateRenderingVisibility()
            updateVinyl()
        } else {
            savePendingPosition()
            background.layer?.removeAnimation(forKey: Self.attentionAnimationKey)
            visibilityFade.hide(panel, animated: animated) { [weak self] in
                self?.updateWindowButtonPlacement()
                self?.updateRenderingVisibility()
                self?.updateVinyl()
            }
        }
        onVisibilityChanged?(visible)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateRenderingVisibility()
    }

    @objc private func screenPowerChanged(_ notification: Notification) {
        screensAwake = notification.name == NSWorkspace.screensDidWakeNotification
        updateRenderingVisibility()
    }

    private func updateRenderingVisibility() {
        if !screensAwake || !panel.isVisible || panel.occlusionState.contains(.visible) {
            pendingOcclusionPause?.cancel()
            pendingOcclusionPause = nil
            setRendersContent(screensAwake && panel.isVisible)
            return
        }

        // Window animations can report a brief occlusion without hiding the panel.
        guard rendersContent, pendingOcclusionPause == nil else { return }
        let pause = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingOcclusionPause = nil
            if !self.panel.occlusionState.contains(.visible) { self.setRendersContent(false) }
        }
        pendingOcclusionPause = pause
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.occlusionPauseDelay, execute: pause)
    }

    private func setRendersContent(_ enabled: Bool) {
        guard rendersContent != enabled else { return }
        rendersContent = enabled
        if enabled { render(status: latestStatus) }
        else { updateVinyl() }
        canvas.setWindowVisible(enabled)
    }

    func apply(status: AppStatus) {
        latestStatus = status
        if rendersContent { render(status: status) }
    }

    private func render(status: AppStatus) {
        let track = status.track
        updateTrackDetails(track)
        controls.update(track)
        updateVinyl()
        switch status {
        case .showing(let track, let lyrics, _):
            canvas.update(track: track, lyrics: lyrics)
        case .loadingLyrics, .noLyrics:
            canvas.showMessage(nil)
        case .error(let message):
            canvas.showMessage(message)
        case .idle, .musicNotRunning, .stopped:
            canvas.showMessage("播放音乐，让歌词流动")
        }
    }

    private func updateTrackDetails(_ track: TrackInfo?) {
        let nextTitle = track?.title ?? "桌面歌词"
        let nextArtist = track?.artist ?? ""
        guard title.stringValue != nextTitle || artist.stringValue != nextArtist else { return }
        let animate = rendersContent && title.toolTip != nil && track != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animate {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.24
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            trackDetails.layer?.add(fade, forKey: "trackDetailsFade")
        }
        title.stringValue = nextTitle
        artist.stringValue = nextArtist
        title.toolTip = track?.title
        artist.toolTip = track?.artist
        if animate { trackDetails.displayIfNeeded() }
        CATransaction.commit()
    }

    func attachTranslationHost(_ host: NSView) {
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        background.content.addSubview(host)
    }

    func setArtwork(_ image: NSImage?) { vinyl.setArtwork(image) }

    func updateHighlight(for track: TrackInfo, lyrics: LyricsDocument) {
        latestStatus = .showing(track: track, lyrics: lyrics, currentLine: "")
        guard rendersContent else { return }
        updateVinyl()
        controls.update(track)
        canvas.update(track: track, lyrics: lyrics)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        windowButtons.forEach { $0.needsDisplay = true }
        updateFocusOutline(selected: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        windowButtons.forEach { $0.needsDisplay = true }
        updateFocusOutline(selected: false)
    }

    private var availableFrame: NSRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func updateSizeLimits() {
        let available = availableFrame.size
        let minimum = mode == .vinyl ? FloatingLyricsMode.minimumVinylSize : FloatingLyricsMode.minimalSize
        panel.contentMinSize = NSSize(width: min(minimum.width, available.width),
                                     height: min(minimum.height, available.height))
        panel.contentMaxSize = mode == .vinyl ? available : panel.contentMinSize
    }

    private func fittingFrame(_ frame: NSRect) -> NSRect {
        let area = availableFrame
        let size = NSSize(width: min(area.width, max(panel.contentMinSize.width, frame.width)),
                          height: min(area.height, max(panel.contentMinSize.height, frame.height)))
        return NSRect(x: max(area.minX, min(frame.minX, area.maxX - size.width)),
                      y: max(area.minY, min(frame.minY, area.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateSizeLimits()
        constrainToScreen()
        canvas.refreshDisplayLink()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        mode == .vinyl ? fittingFrame(NSRect(origin: panel.frame.origin, size: frameSize)).size : panel.frame.size
    }

    func windowDidResize(_ notification: Notification) {
        if mode == .vinyl {
            let frame = panel.frame
            let size = fittingFrame(frame).size
            if frame.size != size {
                // Some programmatic AppKit sizing paths bypass the resize limits.
                let origin = NSPoint(x: frame.minX, y: frame.maxY - size.height)
                panel.setFrame(NSRect(origin: origin, size: size), display: true)
                return
            }
        }
        layoutContent()
        if panel.inLiveResize {
            if resizePreviewTimer == nil {
                let timer = Timer(timeInterval: 0.06, repeats: false) { [weak self] _ in
                    self?.resizePreviewTimer = nil
                    self?.canvas.viewportDidResize()
                }
                resizePreviewTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            canvas.viewportDidResize()
            schedulePositionSave()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard mode == .vinyl else { return }
        resizePreviewTimer?.invalidate()
        resizePreviewTimer = nil
        vinylSize = FloatingLyricsMode.clampedVinylSize(panel.frame.size)
        AppPreferences.floatingLyricsVinylSize = vinylSize
        canvas.viewportDidResize()
        constrainToScreen()
        schedulePositionSave()
    }

    func windowDidMove(_ notification: Notification) {
        schedulePositionSave()
    }

    private func schedulePositionSave() {
        guard !restoringPosition else { return }
        // AppKit can send a burst of move notifications during a single drag.
        // Keep writes in the default run loop mode, after movement settles.
        let delay: TimeInterval = 0.25
        if let positionSaveTimer {
            positionSaveTimer.fireDate = Date(timeIntervalSinceNow: delay)
        } else {
            positionSaveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.savePendingPosition()
            }
        }
    }

    func savePendingPosition() {
        guard let positionSaveTimer else { return }
        positionSaveTimer.invalidate()
        self.positionSaveTimer = nil
        guard let screen = panel.screen else { return }
        var frames = AppPreferences.floatingLyricsFramesByDisplay
        let id = displayID(screen)
        let savedFrame = panel.frame
        let frame = NSStringFromRect(savedFrame)
        if mode == .vinyl {
            vinylSize = FloatingLyricsMode.clampedVinylSize(savedFrame.size)
            AppPreferences.floatingLyricsVinylSize = vinylSize
        }
        if frames[id] != frame {
            frames[id] = frame
            AppPreferences.floatingLyricsFramesByDisplay = frames
        }
        if AppPreferences.floatingLyricsLastDisplay != id {
            AppPreferences.floatingLyricsLastDisplay = id
        }
    }

    private func displayID(_ screen: NSScreen) -> String {
        String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
    }

    private func restorePosition() {
        let frames = AppPreferences.floatingLyricsFramesByDisplay
        let screens = NSScreen.screens.sorted { displayID($0) == AppPreferences.floatingLyricsLastDisplay && displayID($1) != AppPreferences.floatingLyricsLastDisplay }
        for screen in screens {
            if let stored = frames[displayID(screen)] {
                let frame = NSRectFromString(stored)
                guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                      frame.width > 0, frame.height > 0 else { continue }
                panel.setFrameOrigin(frame.origin)
                updateSizeLimits()
                if mode == .vinyl, frame.width >= FloatingLyricsMode.minimumVinylSize.width,
                   frame.height >= FloatingLyricsMode.minimumVinylSize.height {
                    panel.setFrame(frame, display: false)
                }
                constrainToScreen()
                return
            }
        }
        panel.center()
    }

    private func constrainToScreen() {
        let frame = fittingFrame(panel.frame)
        if frame != panel.frame { panel.setFrame(frame, display: false) }
    }
}

private final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class WindowDotButton: ActionButton {
    private let color: NSColor
    private let activeGlyph: NSImage?
    private let inactiveGlyph: NSImage?
    private var cachedBoundsSize: CGSize = .zero
    private var cachedFocusRingBounds: NSRect = .zero
    private var cachedDotPath: NSBezierPath?
    private var hovered = false
    var marked = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, symbol: String, label: String) {
        self.color = color
        let style = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        let baseGlyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(style)
        activeGlyph = baseGlyph?.withSymbolConfiguration(.init(paletteColors: [NSColor.black.withAlphaComponent(0.72)])) ?? baseGlyph
        inactiveGlyph = baseGlyph?.withSymbolConfiguration(.init(paletteColors: [NSColor.labelColor])) ?? baseGlyph
        super.init()
        toolTip = label
        setAccessibilityLabel(label)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override var focusRingMaskBounds: NSRect {
        if bounds.size != cachedBoundsSize {
            cachedBoundsSize = bounds.size
            cachedFocusRingBounds = NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
            cachedDotPath = NSBezierPath(ovalIn: cachedFocusRingBounds)
        }
        return cachedFocusRingBounds
    }

    override func drawFocusRingMask() {
        _ = focusRingMaskBounds
        cachedDotPath?.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let usesColor = (window?.parent ?? window)?.isKeyWindow == true || hovered || isHighlighted
        let color = usesColor ? self.color : NSColor.tertiaryLabelColor
        _ = focusRingMaskBounds
        (isHighlighted ? color.blended(withFraction: 0.17, of: .black) ?? color : color).setFill()
        cachedDotPath?.fill()
        if hovered || marked, let image = usesColor ? activeGlyph : inactiveGlyph {
            let rect = NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        resetHover()
    }

    func resetHover() {
        hovered = false
        needsDisplay = true
    }
}

final class LyricsCanvasView: NSView {
    private struct PendingLyricClick {
        let lineIndex: Int
        let screenLocation: NSPoint
        let mouseDownEvent: NSEvent
    }

    private struct RowIdentity: Equatable {
        let time: TimeInterval
        let text: String
    }

    private enum AnimationSpec {
        static let lyricsRevealDuration: CFTimeInterval = 0.28
        static let lyricsRevealOffset: CGFloat = 6
        static let lyricsRevealKey = "lyricsReveal"
        static let lineStateDuration: CFTimeInterval = 0.28
        static let activeLineScale: CGFloat = 1.04
        static let lineSpringMass: CGFloat = 1
        static let lineSpringStiffness: CGFloat = 195
        static let lineSpringDamping: CGFloat = 20
        static let manualScrollFollowDelay: TimeInterval = 4
        static let lineTapProgressFreezeDuration: TimeInterval = 0.55
        static let featherWidth: CGFloat = 10
        static let maximumContextBlurRadius: CGFloat = 0.825
        static let adjacentContextBlurRadius: CGFloat = 0.4
        static let minimumGapCueDuration: TimeInterval = 3
        static let animationHeadstart: TimeInterval = 0
        static let clickDragThreshold: CGFloat = 5
    }

    private var layoutSize: NSSize { bounds.size }

    private var typographyScale = CGFloat(AppPreferences.fontScale)

    private var horizontalInset: CGFloat {
        min(64, max(20, layoutSize.width * 0.055))
    }

    private var contentOriginX: CGFloat {
        (bounds.width - layoutSize.width) / 2 + horizontalInset
    }

    private var contentWidth: CGFloat {
        max(80, layoutSize.width - horizontalInset * 2)
    }

    private var activeFont: NSFont {
        .systemFont(ofSize: 23 * typographyScale, weight: .bold)
    }

    private var visibleLineRadius: Int {
        let averageHeight = averageLineHeight ?? 39 * typographyScale
        let rowsNeeded = Int(ceil(bounds.height * 0.62 / max(1, averageHeight))) + 1
        return min(18, max(5, rowsNeeded))
    }

    private var sourceLines: [LyricLine] = []
    private var lines: [LyricLine] = []
    private var lineAnimationEndTimes: [TimeInterval] = []
    private var earlierVocalEndTimes: [TimeInterval] = []
    private var overlappingVocalRows = IndexSet()
    private var activeIndex: Int?
    private var message: String?
    private var plainText: String?

    private var lineCenters: [CGFloat] = []
    private var lineHeights: [CGFloat] = []
    private var averageLineHeight: CGFloat?
    private var geometryWidth: CGFloat = 0
    private var geometryInvalid = true
    private var geometryRowIdentities: [RowIdentity] = []
    private var textMeasurer: KaraokeTextMeasurer?

    private lazy var displayLink: any LyricsDisplayLink = {
        let onFrame = { [weak self] in
            guard let self, self.isWindowVisible else { return }
            self.updateLayerPresentation()
        }
        if #available(macOS 14.0, *) { return ScreenLyricsDisplayLink(onFrame: onFrame) }
        return LegacyLyricsDisplayLink(onFrame: onFrame)
    }()
    private var isWindowVisible = false
    private var showsTranslation = true
    private var showsTransliteration = true
    private let contextBlurRadius = AnimationSpec.maximumContextBlurRadius
    private var hoveredLineIndex: Int?
    private var pointerInside = false
    private var browsingIndex: Int?
    private var isManualScrolling = false
    private var autoFollowResumeDeadline: CFTimeInterval = 0
    private var manualScrollEndWorkItem: DispatchWorkItem?
    private var manualScrollResumeWorkItem: DispatchWorkItem?
    private var displayLinkResumeTimer: Timer?
    private var frozenPosition: TimeInterval?
    private var frozenPositionDeadline: CFTimeInterval = 0
    private var pendingLyricClick: PendingLyricClick?

    var onSeek: ((TimeInterval) -> Void)?

    private var basePosition: TimeInterval = 0
    private var sampledAt = CACurrentMediaTime()
    private var isPlaying = false

    private let edgeMask = CAGradientLayer()
    private let lyricsLayer = NoImplicitAnimationLayer()
    private let messageLayer = LyricsCanvasTextLayer()
    private let plainTextLayer = LyricsCanvasTextLayer()
    private var karaokeLayers: [KaraokeLineLayer] = []
    private var visualActiveIndex: Int?
    private var visualGapCueIndex: Int?
    private var visibleRows: Range<Int> = 0..<0
    private var preparedRows = IndexSet()
    private var offscreenRowOpacity: Float = 1
    private var visualScrollIndex: Int?
    private var isScrollStateInitialized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        manualScrollEndWorkItem?.cancel()
        manualScrollResumeWorkItem?.cancel()
        displayLinkResumeTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        lyricsLayer.isGeometryFlipped = true
        // Clip before the feathered viewport mask so offscreen rows can be culled.
        lyricsLayer.masksToBounds = true
        layer?.addSublayer(lyricsLayer)
        messageLayer.drawText = { [weak self] in
            guard let self, let message = self.message else { return }
            self.effectiveAppearance.performAsCurrentDrawingAppearance { self.drawMessage(message) }
        }
        plainTextLayer.drawText = { [weak self] in
            guard let self, let text = self.plainText else { return }
            self.effectiveAppearance.performAsCurrentDrawingAppearance { self.drawPlainText(text) }
        }
        plainTextLayer.opacity = 0
        layer?.addSublayer(plainTextLayer)
        layer?.addSublayer(messageLayer)
        updateTextLayerScale()
        edgeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        edgeMask.locations = [0, 0.12, 0.88, 1]
        edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = edgeMask
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    func setSupplementaryLyrics(showTranslation: Bool, showTransliteration: Bool) {
        guard showsTranslation != showTranslation
                || showsTransliteration != showTransliteration else { return }
        showsTranslation = showTranslation
        showsTransliteration = showTransliteration
        invalidateGeometry()
    }

    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        if !inside { updateHoveredLine(nil) }
    }

    override func layout() {
        super.layout()
        guard edgeMask.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        resetLyricsLayerGeometry()
        messageLayer.frame = bounds
        plainTextLayer.frame = bounds
        CATransaction.commit()
    }

    private func setLyrics(_ document: LyricsDocument, track: TrackInfo) {
        let shouldReveal = lines.isEmpty && plainText == nil
        sourceLines = document.lines
        lines = document.floatingLines
        let separatesVocals = lines.contains { $0.vocalRole != .lead }
        lineAnimationEndTimes = lines.enumerated().map { index, line in
            line.words.lazy.map { $0.start + max(0.01, $0.end - $0.start) }.max()
                ?? (separatesVocals ? line.confirmedEnd : nil)
                ?? fallbackHighlightEnd(at: index)
        }
        earlierVocalEndTimes.removeAll(keepingCapacity: true)
        overlappingVocalRows.removeAll()
        if separatesVocals {
            var previousEnd = -TimeInterval.infinity
            for index in lines.indices {
                earlierVocalEndTimes.append(previousEnd)
                if !lines[index].isGap { previousEnd = max(previousEnd, lineAnimationEndTimes[index]) }
            }
        }
        plainText = nil
        plainTextLayer.opacity = 0
        plainTextLayer.removeAnimation(forKey: AnimationSpec.lyricsRevealKey)
        updateClock(track)
        activeIndex = nil
        invalidateGeometry()
        if shouldReveal { revealLyrics(on: lyricsLayer) }
        updateTimerState()
    }

    func update(track: TrackInfo, lyrics: LyricsDocument) {
        guard lyrics.isSynced else {
            showPlainText(lyrics.plainText ?? "")
            return
        }
        if lyrics.lines != sourceLines {
            setLyrics(lyrics, track: track)
            return
        }
        updateClock(track)
        updateLayerPresentation(resumeDisplayLink: true)
    }

    func showMessage(_ text: String?) {
        guard message != text || !lines.isEmpty || plainText != nil else { return }
        sourceLines = []
        lines = []
        lineAnimationEndTimes = []
        earlierVocalEndTimes = []
        overlappingVocalRows.removeAll()
        plainText = nil
        plainTextLayer.opacity = 0
        message = text
        messageLayer.opacity = 1
        messageLayer.setNeedsDisplay()
        stopRevealAnimations()
        updateTimerState()
        clearKaraokeLayers()
    }

    private func showPlainText(_ text: String) {
        guard plainText != text else { return }
        let shouldReveal = lines.isEmpty && plainText == nil
        sourceLines = []
        lines = []
        lineAnimationEndTimes = []
        earlierVocalEndTimes = []
        overlappingVocalRows.removeAll()
        lyricsLayer.removeAnimation(forKey: AnimationSpec.lyricsRevealKey)
        plainText = text
        plainTextLayer.opacity = 1
        plainTextLayer.setNeedsDisplay()
        updateTimerState()
        clearKaraokeLayers()
        if shouldReveal { revealLyrics(on: plainTextLayer) }
    }

    private func revealLyrics(on target: CALayer) {
        messageLayer.opacity = 0
        guard isWindowVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        messageLayer.displayIfNeeded()
        target.displayIfNeeded()
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = 0.20
        fadeOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        messageLayer.add(fadeOut, forKey: AnimationSpec.lyricsRevealKey)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = AnimationSpec.lyricsRevealDuration
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        let offset = AnimationSpec.lyricsRevealOffset
        rise.fromValue = layer?.isGeometryFlipped == true ? offset : -offset
        rise.toValue = 0
        rise.duration = AnimationSpec.lyricsRevealDuration
        let reveal = CAAnimationGroup()
        reveal.animations = [fadeIn, rise]
        reveal.duration = AnimationSpec.lyricsRevealDuration
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.75, 0.36, 1)
        target.add(reveal, forKey: AnimationSpec.lyricsRevealKey)
    }

    private func stopRevealAnimations() {
        messageLayer.removeAnimation(forKey: AnimationSpec.lyricsRevealKey)
        plainTextLayer.removeAnimation(forKey: AnimationSpec.lyricsRevealKey)
        lyricsLayer.removeAnimation(forKey: AnimationSpec.lyricsRevealKey)
    }

    func invalidateGeometry() {
        typographyScale = CGFloat(AppPreferences.fontScale)
        geometryInvalid = true
        viewportDidResize()
    }

    func viewportDidResize() {
        // Publish the new rows only after positioning and restoring their highlight.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildLayersIfNeeded(exactWidth: true)
        updateLayerPresentation(animateLineChange: false)
        CATransaction.commit()
        if lines.isEmpty {
            messageLayer.setNeedsDisplay()
            plainTextLayer.setNeedsDisplay()
        }
    }

    private func resetLyricsLayerGeometry() {
        lyricsLayer.transform = CATransform3DIdentity
        var layerBounds = lyricsLayer.bounds
        layerBounds.size = bounds.size
        lyricsLayer.bounds = layerBounds
        lyricsLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if !visible { stopRevealAnimations() }
        updateTimerState()
    }

    func refreshDisplayLink() {
        updateTimerState()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let previousScale = plainTextLayer.contentsScale
        updateTextLayerScale()
        if previousScale != plainTextLayer.contentsScale, !lines.isEmpty {
            invalidateGeometry()
        }
    }

    private func updateTextLayerScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for textLayer in [messageLayer, plainTextLayer] where textLayer.contentsScale != scale {
            textLayer.contentsScale = scale
            textLayer.setNeedsDisplay()
        }
    }

    private func rebuildLayersIfNeeded(exactWidth: Bool = false) {
        let widthTolerance: CGFloat = exactWidth ? 0 : 0.5
        guard geometryInvalid || abs(geometryWidth - layoutSize.width) > widthTolerance else { return }
        geometryInvalid = false
        let scale = typographyScale

        // Translations can arrive while the user is reading another part of the song.
        let identities = lines.map { RowIdentity(time: $0.time, text: $0.text) }
        let browsedRow = geometryRowIdentities == identities ? browsingIndex : nil
        let browseOffset = browsedRow.map { index in
            (lyricsLayer.presentation()?.bounds.origin.y ?? lyricsLayer.bounds.origin.y) - scrollTarget(for: index)
        }
        geometryWidth = layoutSize.width
        geometryRowIdentities = identities
        let width = contentWidth
        if textMeasurer?.width != width { textMeasurer = KaraokeTextMeasurer(width: width) }
        guard let textMeasurer else { return }
        let font = activeFont
        let harmonyFont = NSFont.systemFont(ofSize: font.pointSize * 0.82, weight: .semibold)
        let gapFont = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let customColor = AppPreferences.floatingLyricsTextColor
        var lyricColor = customColor ?? NSColor.labelColor
        var supplementaryColor = customColor ?? NSColor.secondaryLabelColor
        // Retained text layers draw outside the view's appearance context.
        // Resolve the palette when building rows so later bitmap draws use the window's colors.
        if customColor == nil {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                lyricColor = lyricColor.usingColorSpace(.sRGB) ?? lyricColor
                supplementaryColor = supplementaryColor.usingColorSpace(.sRGB) ?? supplementaryColor
            }
        }
        var cursor: CGFloat = 0
        lineCenters.removeAll(keepingCapacity: true)
        lineHeights.removeAll(keepingCapacity: true)
        clearKaraokeLayers(preservingBrowse: browsedRow != nil)
        karaokeLayers.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let rowFont = line.isGap ? gapFont : (line.vocalRole.isHarmony ? harmonyFont : font)
            let lineLayer = KaraokeLineLayer(
                line: line,
                fallbackEnd: lineAnimationEndTimes[index],
                font: rowFont,
                textColor: lyricColor,
                increasedContrast: increasedContrast,
                supplementaryText: supplementaryText(for: line, originalFontSize: rowFont.pointSize, color: supplementaryColor),
                measurer: textMeasurer,
                contentsScale: contentsScale,
                featherWidth: AnimationSpec.featherWidth * scale * (line.isGap ? 0.5 : 1)
            )
            let height: CGFloat
            if line.isGap {
                height = hasGapCue(at: index) ? max(18 * scale, lineLayer.textHeight) : scale
            } else if line.vocalRole.isHarmony {
                height = max(32 * scale, lineLayer.textHeight + 12 * scale)
            } else {
                height = max(40 * scale, lineLayer.textHeight + 18 * scale)
            }
            lineHeights.append(height)
            lineCenters.append(cursor + height / 2)
            lineLayer.bounds = CGRect(x: 0, y: 0, width: width, height: lineLayer.textHeight)
            lineLayer.anchorPoint = CGPoint(x: line.vocalRole.isRightAligned ? 1 : 0, y: 0.5)
            lineLayer.isHidden = true
            karaokeLayers.append(lineLayer)
            cursor += height + 5 * scale
        }
        let contentHeight = max(0, cursor - 5 * scale)
        if !lineHeights.isEmpty {
            averageLineHeight = lineHeights.reduce(0, +) / CGFloat(lineHeights.count) + 5 * scale
        }
        let originX = contentOriginX
        for index in karaokeLayers.indices {
            let mirroredCenter = contentHeight - lineCenters[index]
            lineCenters[index] = mirroredCenter
            let x = lines[index].vocalRole.isRightAligned ? originX + width : originX
            karaokeLayers[index].position = CGPoint(x: x, y: mirroredCenter)
        }
        if let browsedRow, let browseOffset {
            setScrollPosition(scrollTarget(for: browsedRow) + browseOffset)
            isScrollStateInitialized = true
        }
        lyricsLayer.isHidden = lines.isEmpty
    }

    private func fallbackHighlightEnd(at index: Int) -> TimeInterval {
        let line = lines[index]
        if index + 1 < lines.count {
            return max(line.time + 0.01, lines[index + 1].time)
        }
        return max(line.time + 2, line.endTime)
    }

    private func drawMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: min(22, 14 * typographyScale),
                    weight: .medium
                ),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        let width = contentWidth
        let height = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        attributed.draw(
            with: NSRect(
                x: contentOriginX,
                y: (bounds.height - height) / 2,
                width: width,
                height: height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func drawPlainText(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 5
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: min(24, 14 * typographyScale),
                    weight: .regular
                ),
                .foregroundColor: AppPreferences.floatingLyricsTextColor ?? NSColor.labelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        attributed.draw(
            with: NSRect(
                x: contentOriginX,
                y: 20 * min(1.6, typographyScale),
                width: contentWidth,
                height: max(0, bounds.height - 40 * min(1.6, typographyScale))
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    func resetPlaybackClock() {
        isPlaying = false
        frozenPosition = nil
        frozenPositionDeadline = 0
        cancelManualScroll()
        autoFollowResumeDeadline = 0
        updateTimerState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateGeometry()
    }

    private func updateClock(_ track: TrackInfo) {
        let now = CACurrentMediaTime()
        if let frozenPosition,
           abs(track.position - frozenPosition) < 0.8 {
            self.frozenPosition = nil
            frozenPositionDeadline = 0
        }
        let estimated = interpolatedPosition(at: now)
        let error = track.position - estimated
        if isPlaying, track.state == .playing, abs(error) < 0.75 {
            basePosition = estimated + error * 0.06
        } else {
            basePosition = track.position
        }
        sampledAt = now
        isPlaying = track.state == .playing
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        if let frozenPosition, now < frozenPositionDeadline {
            return frozenPosition
        }
        return basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }

    private func lineIndex(at position: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        if let active = activeIndex, active < lines.count, lines[active].time <= position {
            let next = active + 1
            if next >= lines.count || position < lines[next].time {
                return active
            }
            let afterNext = next + 1
            if afterNext >= lines.count || position < lines[afterNext].time {
                return next
            }
        }
        var lowerBound = 0
        var upperBound = lines.count - 1
        var result: Int?

        while lowerBound <= upperBound {
            let index = (lowerBound + upperBound) / 2
            if lines[index].time <= position {
                result = index
                lowerBound = index + 1
            } else {
                upperBound = index - 1
            }
        }
        return result
    }

    private func updateLayerPresentation(animateLineChange: Bool = true, resumeDisplayLink: Bool = false) {
        guard !lines.isEmpty else { return }
        // Keep the current line layers while the edge is tracking the pointer.
        // Reflow TextKit once the user finishes resizing.
        if window?.inLiveResize != true { rebuildLayersIfNeeded() }

        let frameTime = CACurrentMediaTime()
        let position = interpolatedPosition(at: frameTime)
        let resolvedIndex: Int
        if let index = lineIndex(at: position) {
            resolvedIndex = index
        } else {
            resolvedIndex = 0
        }
        let lineChanged = activeIndex != resolvedIndex
        let previousIndex = activeIndex
        activeIndex = resolvedIndex
        guard resolvedIndex < karaokeLayers.count else { return }
        defer { updateTimerState(at: frameTime, position: position, resumeDisplayLink: resumeDisplayLink) }
        let highlightPosition = position + AnimationSpec.animationHeadstart
        let previousOverlap = overlappingVocalRows
        overlappingVocalRows = simultaneousVocals(before: resolvedIndex, at: highlightPosition)
        let scrollIndex = focusIndex(for: resolvedIndex)
        let rowsToUpdate = previousOverlap.union(overlappingVocalRows)
        let needsInitialProgress = visualActiveIndex == nil
        var needsLineStateUpdate = lineChanged || visualActiveIndex != resolvedIndex || previousOverlap != overlappingVocalRows
            || visualGapCueIndex != gapCueIndex(for: resolvedIndex, at: highlightPosition)
        let shouldResumeAutoFollow = !isManualScrolling
            && autoFollowResumeDeadline > 0
            && frameTime >= autoFollowResumeDeadline
        if shouldResumeAutoFollow {
            autoFollowResumeDeadline = 0
            visualScrollIndex = nil
            needsLineStateUpdate = true
        }
        let autoFollowSuppressed = browsingIndex != nil || autoFollowResumeDeadline > frameTime
        let needsScrollUpdate = visualScrollIndex != scrollIndex

        // Steady-state glyph changes can join Core Animation's run-loop commit.
        // An explicit transaction is only needed when updating the surrounding rows or scroll.
        if animateLineChange, !needsLineStateUpdate, autoFollowSuppressed || !needsScrollUpdate {
            karaokeLayers[resolvedIndex].updateProgress(position: highlightPosition)
            for index in rowsToUpdate where preparedRows.contains(index) {
                karaokeLayers[index].updateProgress(position: highlightPosition)
            }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needsLineStateUpdate || !animateLineChange {
            updateLineStates(activeIndex: resolvedIndex, animated: animateLineChange, highlightPosition: highlightPosition)
            if needsInitialProgress
                || previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) > 1 {
                for index in preparedRows where index != resolvedIndex {
                    karaokeLayers[index].updateProgress(
                        position: highlightPosition,
                        animated: animateLineChange
                    )
                }
            } else if let previousIndex, previousIndex < karaokeLayers.count {
                karaokeLayers[previousIndex].updateProgress(
                    position: highlightPosition,
                    animated: animateLineChange
                )
            }
        }
        if !autoFollowSuppressed && (needsScrollUpdate || !animateLineChange) {
            visualScrollIndex = scrollIndex
            let isContinuousAdvance = previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) <= 1
            scroll(
                to: scrollIndex,
                animated: animateLineChange && isContinuousAdvance
            )
        }
        karaokeLayers[resolvedIndex].updateProgress(
            position: highlightPosition,
            animated: animateLineChange
        )
        for index in rowsToUpdate where preparedRows.contains(index) {
            karaokeLayers[index].updateProgress(position: highlightPosition, animated: animateLineChange)
        }
        CATransaction.commit()
    }

    private func simultaneousVocals(before index: Int, at position: TimeInterval) -> IndexSet {
        guard earlierVocalEndTimes.indices.contains(index), earlierVocalEndTimes[index] >= position else { return IndexSet() }
        let role = lines[index].vocalRole
        var rows = IndexSet()
        for previous in max(0, index - visibleLineRadius)..<index {
            let line = lines[previous]
            if !line.isGap, (line.vocalRole != role || role.isHarmony), lineAnimationEndTimes[previous] >= position {
                rows.insert(previous)
            }
        }
        return rows
    }

    private func focusIndex(for activeIndex: Int) -> Int {
        if lines[activeIndex].isGap, !hasGapCue(at: activeIndex) {
            return (0..<activeIndex).reversed().first { !lines[$0].isGap }
                ?? ((activeIndex + 1)..<lines.count).first { !lines[$0].isGap }
                ?? activeIndex
        }
        guard lines[activeIndex].vocalRole.isHarmony else { return activeIndex }
        return overlappingVocalRows.reversed().first { !lines[$0].vocalRole.isHarmony } ?? activeIndex
    }

    private func hasGapCue(at index: Int) -> Bool {
        let line = lines[index]
        return line.isGap && lineAnimationEndTimes[index] - line.time >= AnimationSpec.minimumGapCueDuration
    }

    private func gapCueIndex(for index: Int, at position: TimeInterval) -> Int? {
        guard browsingIndex == nil, hasGapCue(at: index),
              position >= lines[index].time, position < lineAnimationEndTimes[index] else { return nil }
        return index
    }

    private func updateLineStates(activeIndex: Int, animated: Bool, highlightPosition: TimeInterval) {
        let previous = visualActiveIndex
        visualActiveIndex = activeIndex
        visualGapCueIndex = gapCueIndex(for: activeIndex, at: highlightPosition)
        let focus = focusIndex(for: activeIndex)
        let visibilityCenter = browsingIndex ?? focus
        let visibleRadius = visibleLineRadius
        visibleRows = max(0, visibilityCenter - visibleRadius)..<min(karaokeLayers.count, visibilityCenter + visibleRadius + 1)
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let browsing = browsingIndex != nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animate = animated && !reduceMotion
        let emphasizesActiveLine = !browsing && !reduceMotion && AppPreferences.smoothScrolling
        let paddedRadius = visibleRadius + 2
        let preparedRange = max(0, visibilityCenter - paddedRadius)..<min(karaokeLayers.count, visibilityCenter + paddedRadius + 1)
        var nextPrepared = IndexSet(integersIn: preparedRange)
        if let previous {
            nextPrepared.insert(integersIn: max(0, previous - 1)..<min(karaokeLayers.count, previous + 2))
        }
        var affected = preparedRows.union(nextPrepared)
        affected.insert(activeIndex)
        if let previous { affected.insert(previous) }
        if preparedRows != nextPrepared {
            for index in preparedRows.subtracting(nextPrepared) {
                karaokeLayers[index].removeFromSuperlayer()
            }
            for (slot, index) in nextPrepared.enumerated() where !preparedRows.contains(index) {
                lyricsLayer.insertSublayer(karaokeLayers[index], at: UInt32(slot))
            }
        }

        for index in affected {
            let lineLayer = karaokeLayers[index]
            let isGap = lines[index].isGap
            let showsGapCue = index == visualGapCueIndex
            let viewportDistance = abs(index - visibilityCenter)
            let isPrepared = nextPrepared.contains(index)
            let wasPrepared = preparedRows.contains(index)
            if isPrepared && (!isGap || showsGapCue) {
                lineLayer.prepareForDisplay(
                    timed: index <= activeIndex,
                    prewarm: index == activeIndex + 1
                )
                if !wasPrepared, index != activeIndex, index <= activeIndex {
                    lineLayer.updateProgress(position: highlightPosition, animated: false)
                }
            } else if wasPrepared {
                lineLayer.discardDisplayLayers()
            }
            if animate, isPrepared, !wasPrepared, index != previous {
                // Hidden rows outside the retained range share the same fade origin.
                lineLayer.setVisualState(
                    opacity: offscreenRowOpacity, scale: 1, blurRadius: 0,
                    hidden: true, animated: false, duration: AnimationSpec.lineStateDuration
                )
            }
            let isSinging = index == activeIndex || overlappingVocalRows.contains(index)
            let isHeldLyric = index == focus && index != activeIndex && lines[activeIndex].isGap
            let isAdjacent = viewportDistance == 1
                || (viewportDistance == 2 && lines[min(index, visibilityCenter) + 1].isGap)
            let opacity: Float
            if showsGapCue {
                opacity = increasedContrast ? 1 : 0.72
            } else if isSinging {
                opacity = 1
            } else if isHeldLyric {
                opacity = increasedContrast ? 1 : 0.88
            } else if increasedContrast || browsing {
                opacity = 0.85
            } else {
                opacity = isAdjacent ? 0.68 : max(0.16, 0.76 - Float(viewportDistance) * 0.13)
            }
            let blurRadius = isAdjacent ? AnimationSpec.adjacentContextBlurRadius : contextBlurRadius
            lineLayer.setVisualState(
                opacity: opacity,
                scale: emphasizesActiveLine && (isSinging || isHeldLyric) && !isGap ? AnimationSpec.activeLineScale : 1,
                blurRadius: !isGap && !isSinging && !isHeldLyric && !increasedContrast && !browsing ? blurRadius : 0,
                hidden: viewportDistance > visibleRadius || (isGap && !showsGapCue),
                animated: animate,
                duration: AnimationSpec.lineStateDuration
            )
        }
        if let hoveredLineIndex, !visibleRows.contains(hoveredLineIndex) || karaokeLayers[hoveredLineIndex].isHidden {
            updateHoveredLine(nil)
        }
        preparedRows = nextPrepared
        offscreenRowOpacity = increasedContrast || browsing ? 0.85 : 0.16
    }

    private func scrollTarget(for index: Int) -> CGFloat {
        // Center the active line above the midpoint, with room for wrapped text.
        let inset = 10 * typographyScale
        let halfHeight = karaokeLayers[index].textHeight / 2
        let visualCenter = max(inset + halfHeight, min(bounds.height * 0.36, bounds.height - inset - halfHeight))
        return lineCenters[index] - bounds.height + visualCenter
    }

    private func scroll(to index: Int, animated: Bool) {
        let target = scrollTarget(for: index)
        if !isScrollStateInitialized {
            isScrollStateInitialized = true
            setScrollPosition(target)
            return
        }

        guard animated,
              AppPreferences.smoothScrolling,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            lyricsLayer.removeAnimation(forKey: "lineScroll")
            setScrollPosition(target)
            return
        }

        let current = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        setScrollPosition(target)
        let spring = CASpringAnimation(keyPath: "bounds.origin.y")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = AnimationSpec.lineSpringMass
        spring.stiffness = AnimationSpec.lineSpringStiffness
        spring.damping = AnimationSpec.lineSpringDamping
        spring.duration = spring.settlingDuration
        lyricsLayer.add(spring, forKey: "lineScroll")
    }

    private func setScrollPosition(_ position: CGFloat) {
        var newBounds = lyricsLayer.bounds
        newBounds.origin.y = position
        lyricsLayer.bounds = newBounds
    }

    private func clearKaraokeLayers(preservingBrowse: Bool = false) {
        lyricsLayer.sublayers = nil
        karaokeLayers.removeAll(keepingCapacity: !lines.isEmpty)
        preparedRows.removeAll()
        offscreenRowOpacity = 1
        visibleRows = 0..<0
        averageLineHeight = nil
        visualActiveIndex = nil
        visualGapCueIndex = nil
        visualScrollIndex = nil
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        if !preservingBrowse { cancelManualScroll() }
        pendingLyricClick = nil
        autoFollowResumeDeadline = 0
        isScrollStateInitialized = false
        lyricsLayer.isHidden = lines.isEmpty
    }

    private func supplementaryText(for line: LyricLine, originalFontSize: CGFloat, color: NSColor) -> NSAttributedString? {
        let text = NSMutableAttributedString()
        let paragraph = KaraokeTextLayout.paragraphStyle(rightAligned: line.vocalRole.isRightAligned)
        if showsTransliteration,
           let transliteration = line.transliteration,
           !transliteration.isEmpty {
            text.append(NSAttributedString(string: transliteration, attributes: [
                .font: NSFont.systemFont(ofSize: max(11, originalFontSize * 0.80)),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }
        if showsTranslation,
           let translation = line.translation,
           !translation.isEmpty {
            let prefix = text.length > 0 ? "\n" : ""
            text.append(NSAttributedString(string: prefix + translation, attributes: [
                .font: NSFont.systemFont(ofSize: max(11, originalFontSize * 0.75)),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }
        return text.length > 0 ? text : nil
    }

    override func scrollWheel(with event: NSEvent) {
        pendingLyricClick = nil
        guard !lines.isEmpty else {
            super.scrollWheel(with: event)
            return
        }

        let current = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let proposed = current + event.scrollingDeltaY * multiplier
        guard let first = lineCenters.indices.first(where: { !lines[$0].isGap }),
              let last = lineCenters.indices.last(where: { !lines[$0].isGap }) else { return }
        let minimum = scrollTarget(for: last)
        let maximum = scrollTarget(for: first)
        let position = min(maximum, max(minimum, proposed))

        isScrollStateInitialized = true
        isManualScrolling = true
        autoFollowResumeDeadline = 0
        activateTimer()
        setScrollPosition(position)
        let nearest = nearestLineIndex(toScrollPosition: position)
        let changedRow = browsingIndex != nearest
        browsingIndex = nearest
        visualScrollIndex = nil
        updateHoveredLine(nil)
        if changedRow, let activeIndex {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let frameTime = CACurrentMediaTime()
            let highlightPosition = interpolatedPosition(at: frameTime) + AnimationSpec.animationHeadstart
            updateLineStates(activeIndex: activeIndex, animated: false, highlightPosition: highlightPosition)
            CATransaction.commit()
        }

        manualScrollEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishManualScroll()
        }
        manualScrollEndWorkItem = workItem
        let delay: TimeInterval = event.momentumPhase == .ended ? 0.04 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        manualScrollResumeWorkItem?.cancel()
        let resume = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cancelManualScroll()
            self.visualActiveIndex = nil
            self.visualScrollIndex = nil
            if self.isWindowVisible { self.updateLayerPresentation() }
        }
        manualScrollResumeWorkItem = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + AnimationSpec.manualScrollFollowDelay, execute: resume)
    }

    private func cancelManualScroll() {
        browsingIndex = nil
        isManualScrolling = false
        manualScrollEndWorkItem?.cancel()
        manualScrollEndWorkItem = nil
        manualScrollResumeWorkItem?.cancel()
        manualScrollResumeWorkItem = nil
    }

    private func finishManualScroll() {
        manualScrollEndWorkItem = nil
        guard isManualScrolling else { return }
        isManualScrolling = false
        let visiblePosition = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        guard let index = nearestLineIndex(toScrollPosition: visiblePosition) else { return }
        browsingIndex = index
        scroll(to: index, animated: true)
        if let activeIndex {
            let frameTime = CACurrentMediaTime()
            let highlightPosition = interpolatedPosition(at: frameTime) + AnimationSpec.animationHeadstart
            updateLineStates(activeIndex: activeIndex, animated: true, highlightPosition: highlightPosition)
        }
    }

    private func nearestLineIndex(toScrollPosition position: CGFloat) -> Int? {
        guard var upper = lineCenters.indices.last else { return nil }
        var lower = 0
        // Targets decrease in lyric order, even when wrapped rows vary in height.
        while lower < upper {
            let middle = (lower + upper) / 2
            if scrollTarget(for: middle) > position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let earlier = (0..<lower).reversed().first { !lines[$0].isGap }
        let later = (lower..<lineCenters.count).first { !lines[$0].isGap }
        guard let earlier, let later else { return earlier ?? later }
        return abs(scrollTarget(for: earlier) - position) <= abs(scrollTarget(for: later) - position) ? earlier : later
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerInside else {
            updateHoveredLine(nil)
            return
        }
        updateHoveredLine(lyricLineIndex(at: event, hitSlop: 0.7))
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateHoveredLine(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Mouse movement has already resolved the row against the exact
        // presentation shown to the user. Prefer that stable result because a
        // spring scroll can advance between mouseMoved and mouseDown.
        let clickedIndex = hoveredLineIndex ?? lyricLineIndex(at: event, hitSlop: 1)
        guard let selectedIndex = clickedIndex,
              selectedIndex < lines.count else {
            pendingLyricClick = nil
            super.mouseDown(with: event)
            return
        }
        updateHoveredLine(selectedIndex)
        pendingLyricClick = PendingLyricClick(
            lineIndex: selectedIndex,
            screenLocation: NSEvent.mouseLocation,
            mouseDownEvent: event
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if let pendingLyricClick,
           distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
                > AnimationSpec.clickDragThreshold {
            self.pendingLyricClick = nil
            if let window, window.isMovable, !window.ignoresMouseEvents {
                window.performDrag(with: pendingLyricClick.mouseDownEvent)
                return
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingLyricClick else {
            super.mouseUp(with: event)
            return
        }
        self.pendingLyricClick = nil
        guard distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
                <= AnimationSpec.clickDragThreshold else {
            super.mouseUp(with: event)
            return
        }
        seek(toLineAt: pendingLyricClick.lineIndex)
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func seek(toLineAt selectedIndex: Int) {
        let target = lines[selectedIndex].time
        DiagnosticLogger.shared.info(
            "Lyric click; index=\(selectedIndex); time=\(target)"
        )
        let now = CACurrentMediaTime()
        frozenPosition = target
        frozenPositionDeadline = now + AnimationSpec.lineTapProgressFreezeDuration
        basePosition = target
        sampledAt = now
        cancelManualScroll()
        autoFollowResumeDeadline = frozenPositionDeadline
        visualScrollIndex = nil
        scroll(to: selectedIndex, animated: true)
        updateLayerPresentation()
        onSeek?(target)
    }

    private func lyricLineIndex(at event: NSEvent, hitSlop: CGFloat) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let visibleBounds = lyricsLayer.animation(forKey: "lineScroll") == nil
            ? lyricsLayer.bounds
            : lyricsLayer.presentation()?.bounds ?? lyricsLayer.bounds
        // The lyric container flips its sublayer geometry. Mirror through the
        // currently presented bounds so hover tracks the rendered row while a
        // spring scroll is in flight.
        let contentY = visibleBounds.maxY - point.y
        var nearest: Int?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for index in visibleRows where !karaokeLayers[index].isHidden {
            let distance = abs(lineCenters[index] - contentY)
            if distance < nearestDistance {
                nearest = index
                nearestDistance = distance
            }
        }
        guard let nearest,
              nearestDistance <= lineHeights[nearest] * 0.5 + 6 * hitSlop else {
            return nil
        }
        return nearest
    }

    private func updateHoveredLine(_ index: Int?) {
        guard hoveredLineIndex != index else { return }
        if let hoveredLineIndex, hoveredLineIndex < karaokeLayers.count {
            karaokeLayers[hoveredLineIndex].setHovered(false)
        }
        hoveredLineIndex = index
        if let index, index < karaokeLayers.count {
            karaokeLayers[index].setHovered(true)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func needsAnimation(at frameTime: CFTimeInterval, position: TimeInterval) -> Bool {
        guard isPlaying, isWindowVisible, !lines.isEmpty else { return false }
        if isManualScrolling || browsingIndex != nil || autoFollowResumeDeadline > frameTime {
            return true
        }
        if lyricsLayer.animation(forKey: "lineScroll") != nil
            || lyricsLayer.animation(forKey: AnimationSpec.lyricsRevealKey) != nil
            || plainTextLayer.animation(forKey: AnimationSpec.lyricsRevealKey) != nil {
            return true
        }
        let highlightPosition = position + AnimationSpec.animationHeadstart
        if overlappingVocalRows.contains(where: { highlightPosition <= lineAnimationEndTimes[$0] }) { return true }

        let index = activeIndex ?? 0
        guard index < lines.count else { return false }
        let currentLine = lines[index]

        if currentLine.isGap {
            let nextIndex = index + 1
            if nextIndex < lines.count {
                let nextStart = lines[nextIndex].time - AnimationSpec.animationHeadstart
                return position >= nextStart
            }
            return false
        }

        let lineStart = currentLine.time - AnimationSpec.animationHeadstart
        if position < lineStart {
            return false
        }

        if highlightPosition <= lineAnimationEndTimes[index] {
            return true
        }

        let nextIndex = index + 1
        if nextIndex < lines.count {
            let nextStart = lines[nextIndex].time - AnimationSpec.animationHeadstart
            if position >= nextStart {
                return true
            }
        }
        return false
    }

    private func nextAnimationPosition(after currentPosition: TimeInterval) -> TimeInterval? {
        let index = activeIndex ?? 0
        guard lines.indices.contains(index) else { return nil }
        let currentLine = lines[index]
        let lineStart = currentLine.time - AnimationSpec.animationHeadstart
        if currentPosition < lineStart { return lineStart }
        let next = lines.indices.contains(index + 1) ? lines[index + 1].time - AnimationSpec.animationHeadstart : nil
        if gapCueIndex(for: index, at: currentPosition) != nil {
            let cueEnd = lineAnimationEndTimes[index]
            let nextDot = currentLine.words.first { $0.start > currentPosition }?.start ?? cueEnd
            return min(next ?? cueEnd, nextDot)
        }
        return next
    }

    private func scheduleNextAnimationWakeup(at frameTime: CFTimeInterval, currentPosition: TimeInterval) {
        guard isPlaying, isWindowVisible, let target = nextAnimationPosition(after: currentPosition),
              target > currentPosition else {
            displayLinkResumeTimer?.invalidate()
            displayLinkResumeTimer = nil
            return
        }
        let delay = max(0.01, target - currentPosition - max(0, CACurrentMediaTime() - frameTime))
        let fireDate = Date(timeIntervalSinceNow: delay)
        let tolerance = min(0.05, delay * 0.1)
        if let timer = displayLinkResumeTimer, timer.isValid {
            // Playback samples usually predict the same boundary. Only move
            // the existing timer when the playback clock materially changes.
            if abs(timer.fireDate.timeIntervalSince(fireDate)) > 0.005 {
                timer.fireDate = fireDate
                timer.tolerance = tolerance
            }
            return
        }
        let timer = Timer(fire: fireDate, interval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isPlaying, self.isWindowVisible else { return }
            self.displayLinkResumeTimer = nil
            self.activateTimer()
            self.updateLayerPresentation()
        }
        timer.tolerance = tolerance
        displayLinkResumeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func activateTimer() {
        guard isPlaying, isWindowVisible, !lines.isEmpty else { return }
        displayLinkResumeTimer?.invalidate()
        displayLinkResumeTimer = nil
        displayLink.start(on: window?.screen)
    }

    private func updateTimerState() {
        let now = CACurrentMediaTime()
        updateTimerState(at: now, position: interpolatedPosition(at: now), resumeDisplayLink: true)
    }

    private func updateTimerState(at now: CFTimeInterval, position: TimeInterval, resumeDisplayLink: Bool) {
        if needsAnimation(at: now, position: position) {
            if resumeDisplayLink { activateTimer() }
        } else {
            stopTimer()
            scheduleNextAnimationWakeup(at: now, currentPosition: position)
        }
    }

    private func stopTimer() {
        displayLink.stop()
    }
}

private protocol LyricsDisplayLink: AnyObject {
    func start(on screen: NSScreen?)
    func stop()
}

@available(macOS 14.0, *)
private final class ScreenLyricsDisplayLink: LyricsDisplayLink {
    private final class Target: NSObject {
        let onFrame: () -> Void

        init(onFrame: @escaping () -> Void) { self.onFrame = onFrame }

        @objc func tick(_ sender: CADisplayLink) { onFrame() }
    }

    private let target: Target
    private var displayLink: CADisplayLink?
    private var currentScreen: NSScreen?
    private var preferredRate: Float = 0

    init(onFrame: @escaping () -> Void) { target = Target(onFrame: onFrame) }

    deinit { displayLink?.invalidate() }

    func start(on screen: NSScreen?) {
        guard let screen = screen ?? currentScreen ?? NSScreen.main else { return }
        let screenRate = screen.maximumFramesPerSecond
        let rateLimit = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
        let rate = Float(min(rateLimit, screenRate > 0 ? screenRate : 60))
        if screen == currentScreen, let displayLink {
            if rate != preferredRate { configure(displayLink, rate: rate) }
            if displayLink.isPaused { displayLink.isPaused = false }
            return
        }
        displayLink?.invalidate()
        let link = screen.displayLink(target: target, selector: #selector(Target.tick(_:)))
        configure(link, rate: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
        currentScreen = screen
    }

    private func configure(_ link: CADisplayLink, rate: Float) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
        preferredRate = rate
    }

    func stop() { displayLink?.isPaused = true }
}

private final class LegacyLyricsDisplayLink: LyricsDisplayLink {
    private let onFrame: () -> Void
    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var framePending = false

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        stop()
    }

    func start(on _: NSScreen?) {
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
                  let link else { return }
            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    Unmanaged<LegacyLyricsDisplayLink>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                        .scheduleFrame()
                    return kCVReturnSuccess
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            displayLink = link
        }
        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else { return }
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let displayLink, CVDisplayLinkIsRunning(displayLink) else { return }
        CVDisplayLinkStop(displayLink)
        lock.lock()
        framePending = false
        lock.unlock()
    }

    private func scheduleFrame() {
        lock.lock()
        guard !framePending else {
            lock.unlock()
            return
        }
        framePending = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.framePending = false
            self.lock.unlock()
            self.onFrame()
        }
    }
}

// MARK: - Retained karaoke layers

private class NoImplicitAnimationLayer: CALayer {
    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func action(forKey event: String) -> (any CAAction)? {
        nil
    }

    func drawInTextCoordinates(_ context: CGContext, draw: () -> Void) {
        context.saveGState()
        defer { context.restoreGState() }
        // TextKit uses a top-left origin. Off-tree glyph layers can be drawn
        // before Core Animation knows the flipped geometry of their parent row.
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        draw()
    }
}

private final class NoImplicitAnimationGradientLayer: CAGradientLayer {
    override func action(forKey event: String) -> (any CAAction)? {
        nil
    }
}

private final class LyricsCanvasTextLayer: NoImplicitAnimationLayer {
    var drawText: (() -> Void)?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        drawText = (layer as? LyricsCanvasTextLayer)?.drawText
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(in context: CGContext) {
        context.clear(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawText?()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private struct KaraokeTextLayout {
    private static let leftParagraph = makeParagraph(alignment: .left)
    private static let rightParagraph = makeParagraph(alignment: .right)

    static func paragraphStyle(rightAligned: Bool) -> NSParagraphStyle {
        rightAligned ? rightParagraph : leftParagraph
    }

    private static func makeParagraph(alignment: NSTextAlignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        return paragraph
    }

    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container: NSTextContainer

    init(width: CGFloat) {
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func setText(_ text: NSAttributedString) {
        storage.setAttributedString(text)
    }

    func measureHeight() -> CGFloat {
        manager.ensureLayout(for: container)
        return ceil(max(1, manager.usedRect(for: container).height))
    }
}

private final class KaraokeTextMeasurer {
    let width: CGFloat
    private let layout: KaraokeTextLayout
    private let heights = NSCache<NSAttributedString, NSNumber>()

    init(width: CGFloat) {
        self.width = width
        layout = KaraokeTextLayout(width: width)
        heights.countLimit = 768
        heights.totalCostLimit = 384 * 1024
    }

    func height(for text: NSAttributedString) -> CGFloat {
        if let cached = heights.object(forKey: text) { return CGFloat(cached.doubleValue) }
        layout.setText(text)
        let height = layout.measureHeight()
        heights.setObject(NSNumber(value: Double(height)), forKey: text, cost: text.length * 2)
        return height
    }
}

private final class KaraokeTextLayer: NoImplicitAnimationLayer {
    struct GlyphFragment {
        let glyphRange: NSRange
        let rect: CGRect
    }

    private let storage: NSTextStorage
    private let textLayoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private lazy var lineFragmentRanges: [NSRange] = {
        let total = textLayoutManager.glyphRange(for: textContainer)
        var ranges: [NSRange] = []
        textLayoutManager.enumerateLineFragments(forGlyphRange: total) { _, _, _, glyphRange, _ in
            ranges.append(glyphRange)
        }
        return ranges
    }()

    init(text: NSAttributedString, width: CGFloat, height: CGFloat, scale: CGFloat) {
        let layout = KaraokeTextLayout(width: width)
        layout.setText(text)
        storage = layout.storage
        textLayoutManager = layout.manager
        textContainer = layout.container

        super.init()
        contentsScale = scale
        drawsAsynchronously = false
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? KaraokeTextLayer else {
            fatalError("Unexpected layer copy")
        }
        storage = source.storage
        textLayoutManager = source.textLayoutManager
        textContainer = source.textContainer
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        drawInTextCoordinates(context) {
            drawGlyphs(
                in: context,
                glyphRange: textLayoutManager.glyphRange(for: textContainer),
                at: .zero
            )
        }
    }

    func drawGlyphs(in context: CGContext, glyphRange: NSRange, at origin: CGPoint, color: NSColor? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let characterRange = color.map { _ in
            textLayoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        }
        if let color, let characterRange {
            textLayoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: characterRange)
        }
        defer {
            if let characterRange {
                textLayoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: characterRange)
            }
        }
        textLayoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
    }

    func prepareForDisplay() {
        // Discarded offscreen rows release their bitmap but retain TextKit layout.
        // Mark the layer dirty before explicitly rasterizing it again.
        if contents == nil { setNeedsDisplay() }
        displayIfNeeded()
    }

    func fragments(for characterRange: NSRange) -> [GlyphFragment] {
        let glyphRange = textLayoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return [] }
        var result: [GlyphFragment] = []
        let targetEnd = NSMaxRange(glyphRange)
        for lineRange in lineFragmentRanges {
            if lineRange.location >= targetEnd { break }
            let intersection = NSIntersectionRange(lineRange, glyphRange)
            if intersection.length > 0 {
                result.append(
                    GlyphFragment(
                        glyphRange: intersection,
                        rect: textLayoutManager.boundingRect(
                            forGlyphRange: intersection,
                            in: textContainer
                        )
                    )
                )
            }
        }
        return result
    }
}

private final class KaraokeGlyphFragmentLayer: NoImplicitAnimationLayer {
    private let source: KaraokeTextLayer
    private let glyphRange: NSRange
    private let textRect: CGRect
    private let color: NSColor?

    init(source: KaraokeTextLayer, fragment: KaraokeTextLayer.GlyphFragment, color: NSColor? = nil) {
        self.source = source
        glyphRange = fragment.glyphRange
        textRect = fragment.rect
        self.color = color
        super.init()
        contentsScale = source.contentsScale
        drawsAsynchronously = false
        frame = fragment.rect
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let sourceLayer = layer as? KaraokeGlyphFragmentLayer else {
            fatalError("Unexpected layer copy")
        }
        source = sourceLayer.source
        glyphRange = sourceLayer.glyphRange
        textRect = sourceLayer.textRect
        color = sourceLayer.color
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        drawInTextCoordinates(context) {
            source.drawGlyphs(
                in: context,
                glyphRange: glyphRange,
                at: CGPoint(x: -textRect.minX, y: -textRect.minY),
                color: color
            )
        }
    }

    func prepareForDisplay() {
        displayIfNeeded()
    }
}

private final class ProgressMaskSegmentLayer: NoImplicitAnimationLayer {
    private let fillLayer: NoImplicitAnimationLayer
    private let gradientLayer: NoImplicitAnimationGradientLayer
    private var segmentWidth: CGFloat = 0
    private var featherWidth: CGFloat = 1

    override init() {
        fillLayer = NoImplicitAnimationLayer()
        gradientLayer = NoImplicitAnimationGradientLayer()
        super.init()
        masksToBounds = true
        fillLayer.backgroundColor = NSColor.white.cgColor
        gradientLayer.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        gradientLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fillLayer.anchorPoint = .zero
        fillLayer.position = .zero
        gradientLayer.anchorPoint = .zero
        addSublayer(fillLayer)
        addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? ProgressMaskSegmentLayer else {
            fatalError("Unexpected layer copy")
        }
        fillLayer = source.fillLayer
        gradientLayer = source.gradientLayer
        segmentWidth = source.segmentWidth
        featherWidth = source.featherWidth
        super.init(layer: layer)
    }

    func configure(for highlightedGlyph: CALayer, featherWidth: CGFloat) {
        let rect = highlightedGlyph.bounds
        segmentWidth = rect.width
        self.featherWidth = min(featherWidth, max(1, rect.width))
        frame = rect.insetBy(dx: 0, dy: -2)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: self.featherWidth, height: bounds.height)
        gradientLayer.position = CGPoint(x: -self.featherWidth, y: 0)
    }

    func update(fraction: CGFloat) {
        let width = segmentWidth * fraction
        var fillBounds = fillLayer.bounds
        fillBounds.size.width = max(0, width - featherWidth)
        fillLayer.bounds = fillBounds
        gradientLayer.position = CGPoint(x: width - featherWidth, y: 0)
    }
}

private final class TimedGlyphUnitLayer: NoImplicitAnimationLayer {
    private let lift: CGFloat
    private var fragmentLayers: [KaraokeGlyphFragmentLayer] = []
    private var isLifted = false

    init(size: CGSize, lift: CGFloat) {
        self.lift = lift
        super.init()
        bounds = CGRect(origin: .zero, size: size)
        anchorPoint = .zero
        position = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? TimedGlyphUnitLayer else {
            fatalError("Unexpected layer copy")
        }
        lift = source.lift
        fragmentLayers = source.fragmentLayers
        isLifted = source.isLifted
        super.init(layer: layer)
    }

    func addFragment(_ layer: KaraokeGlyphFragmentLayer) {
        fragmentLayers.append(layer)
        addSublayer(layer)
    }

    func prepareForDisplay() {
        fragmentLayers.forEach { $0.prepareForDisplay() }
    }

    func setLifted(_ lifted: Bool, animated: Bool) {
        guard isLifted != lifted else { return }
        isLifted = lifted
        let target = CATransform3DMakeTranslation(0, lifted ? -lift : 0, 0)

        guard animated, superlayer != nil else {
            transform = target
            removeAnimation(forKey: "syllableLift")
            return
        }
        // Read the presented position only when reversing an in-flight spring.
        let current = animation(forKey: "syllableLift") != nil
            ? presentation()?.transform ?? transform
            : transform
        transform = target
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 14
        spring.damping = 7
        spring.duration = spring.settlingDuration
        add(spring, forKey: "syllableLift")
    }
}

private final class KaraokeLineLayer: NoImplicitAnimationLayer {
    private struct TimedRange {
        let characterRange: NSRange
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct TimedMask {
        let start: TimeInterval
        let end: TimeInterval
        let highlightedGlyph: CALayer
        let featherWidth: CGFloat
        private var activeMask: ProgressMaskSegmentLayer?
        private var lastFraction: CGFloat = -1

        mutating func update(at position: TimeInterval, pool: inout [ProgressMaskSegmentLayer]) {
            let fraction: Double
            if position <= start {
                fraction = 0
            } else if position >= end {
                fraction = 1
            } else {
                fraction = (position - start) / max(0.01, end - start)
            }
            update(fraction: fraction, pool: &pool)
        }

        mutating func update(fraction rawFraction: Double, pool: inout [ProgressMaskSegmentLayer]) {
            let fraction = CGFloat(min(1, max(0, rawFraction)))
            guard fraction != lastFraction else { return }
            if lastFraction < 0 || (fraction == 0) != (lastFraction == 0) {
                highlightedGlyph.isHidden = fraction == 0
            }
            lastFraction = fraction

            guard fraction > 0, fraction < 1 else {
                if let mask = activeMask {
                    highlightedGlyph.mask = nil
                    activeMask = nil
                    if pool.count < 8 { pool.append(mask) }
                }
                return
            }

            let mask: ProgressMaskSegmentLayer
            if let active = activeMask {
                mask = active
            } else {
                mask = pool.popLast() ?? ProgressMaskSegmentLayer()
                mask.configure(for: highlightedGlyph, featherWidth: featherWidth)
                activeMask = mask
                highlightedGlyph.mask = mask
            }
            mask.update(fraction: fraction)
        }

        mutating func detach() {
            if activeMask != nil {
                highlightedGlyph.mask = nil
                activeMask = nil
            }
        }
    }

    private struct TimedUnit {
        let start: TimeInterval
        let layer: TimedGlyphUnitLayer
    }

    private struct ProgressEvent {
        enum Change {
            case maskStarts(Int)
            case maskEnds(Int)
            case lift(Int)
        }

        let time: TimeInterval
        let change: Change
    }

    private let originalText: NSAttributedString
    private let supplementaryText: NSAttributedString?
    private let originalHeight: CGFloat
    private let supplementaryHeight: CGFloat?
    private let originalTextIsEmpty: Bool
    private var upcomingLayer: KaraokeTextLayer?
    private var supplementaryLayer: KaraokeTextLayer?
    private let makeTimedGlyphs: (KaraokeLineLayer, KaraokeTextLayer) -> Void
    private var hasTimedGlyphs = false
    private var lastProgressPosition: TimeInterval?
    private var timedMasks: [TimedMask] = []
    private var timedUnits: [TimedUnit] = []
    private var maskPool: [ProgressMaskSegmentLayer] = []
    private var progressEvents: [ProgressEvent]?
    private var processedEventCount = 0
    private var partialMasks: Set<Int> = []
    private var baseOpacity: Float = 1
    private var isHovered = false
    private var blurRadius: CGFloat = 0
    private var appliedBlurRadius: CGFloat = 0
    private var cachedBlur: (radius: CGFloat, filter: CIFilter)?

    let textHeight: CGFloat

    init(
        line: LyricLine,
        fallbackEnd: TimeInterval,
        font: NSFont,
        textColor: NSColor,
        increasedContrast: Bool,
        supplementaryText: NSAttributedString?,
        measurer: KaraokeTextMeasurer,
        contentsScale: CGFloat,
        featherWidth: CGFloat
    ) {
        let text = line.words.isEmpty ? line.text : line.words.map(\.text).joined()
        let paragraph = KaraokeTextLayout.paragraphStyle(rightAligned: line.vocalRole.isRightAligned)
        originalText = NSAttributedString(string: text.isEmpty ? "·" : text, attributes: [
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(increasedContrast ? 0.75 : 0.52),
            .paragraphStyle: paragraph
        ])
        originalHeight = measurer.height(for: originalText)
        originalTextIsEmpty = text.isEmpty
        self.supplementaryText = supplementaryText
        supplementaryHeight = supplementaryText.map(measurer.height(for:))
        textHeight = originalHeight + (supplementaryHeight.map { 5 + $0 } ?? 0)
        makeTimedGlyphs = { row, source in
            row.buildTimedGlyphs(
                for: line, text: text, source: source, fallbackEnd: fallbackEnd, font: font,
                color: textColor.withAlphaComponent(0.98), featherWidth: featherWidth
            )
        }
        super.init()
        isGeometryFlipped = true
        cornerRadius = 6
        rasterizationScale = contentsScale
    }

    private func buildTimedGlyphs(for line: LyricLine, text: String, source: KaraokeTextLayer,
                                  fallbackEnd: TimeInterval, font: NSFont, color: NSColor, featherWidth: CGFloat) {
        var location = 0
        var ranges: [TimedRange] = []
        if line.words.isEmpty {
            let length = (text as NSString).length
            if length > 0 {
                ranges.append(
                    TimedRange(
                        characterRange: NSRange(location: 0, length: length),
                        start: line.time,
                        end: fallbackEnd
                    )
                )
            }
        } else {
            for word in line.words {
                let length = (word.text as NSString).length
                if length > 0 {
                    ranges.append(
                        TimedRange(
                            characterRange: NSRange(location: location, length: length),
                            start: word.start,
                            end: word.end
                        )
                    )
                }
                location += length
            }
        }
        for range in ranges {
            let characterRanges = composedCharacterRanges(
                in: text,
                range: range.characterRange
            )
            let visualRanges = characterRanges.isEmpty
                ? [range.characterRange]
                : characterRanges
            let glyphGroups = visualRanges.map { characterRange in
                let fragments = source.fragments(for: characterRange)
                return (fragments: fragments, width: fragments.reduce(CGFloat(0)) { $0 + $1.rect.width })
            }
            let totalWidth = glyphGroups.reduce(CGFloat(0)) { $0 + $1.width }
            let duration = max(0.01, range.end - range.start)
            var consumedWidth: CGFloat = 0
            for (fragments, unitWidth) in glyphGroups {
                guard unitWidth > 0 else { continue }
                let unitStart = range.start
                    + duration * TimeInterval(consumedWidth / max(1, totalWidth))
                let unitEnd = range.start
                    + duration * TimeInterval(
                        (consumedWidth + unitWidth) / max(1, totalWidth)
                    )
                consumedWidth += unitWidth

                let unit = TimedGlyphUnitLayer(
                    size: bounds.size,
                    lift: max(1.5, font.pointSize * 0.12)
                )
                var fragmentWidth: CGFloat = 0
                for fragment in fragments where fragment.rect.width > 0 {
                    let fragmentStart = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)
                    fragmentWidth += fragment.rect.width
                    let fragmentEnd = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)

                    let upcomingSlice = KaraokeGlyphFragmentLayer(
                        source: source,
                        fragment: fragment
                    )
                    let highlightedSlice = KaraokeGlyphFragmentLayer(
                        source: source,
                        fragment: fragment,
                        color: color
                    )
                    highlightedSlice.isHidden = true
                    unit.addFragment(upcomingSlice)
                    unit.addFragment(highlightedSlice)
                    timedMasks.append(
                        TimedMask(
                            start: fragmentStart,
                            end: fragmentEnd,
                            highlightedGlyph: highlightedSlice,
                            featherWidth: featherWidth
                        )
                    )
                }
                timedUnits.append(TimedUnit(start: unitStart, layer: unit))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func composedCharacterRanges(in text: String, range: NSRange) -> [NSRange] {
        guard let stringRange = Range(range, in: text) else { return [] }
        var result: [NSRange] = []
        text.enumerateSubstrings(
            in: stringRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            result.append(NSRange(substringRange, in: text))
        }
        return result
    }

    override init(layer: Any) {
        guard let source = layer as? KaraokeLineLayer else {
            fatalError("Unexpected layer copy")
        }
        originalText = source.originalText
        supplementaryText = source.supplementaryText
        originalHeight = source.originalHeight
        supplementaryHeight = source.supplementaryHeight
        originalTextIsEmpty = source.originalTextIsEmpty
        upcomingLayer = source.upcomingLayer
        supplementaryLayer = source.supplementaryLayer
        makeTimedGlyphs = source.makeTimedGlyphs
        hasTimedGlyphs = source.hasTimedGlyphs
        lastProgressPosition = source.lastProgressPosition
        timedMasks = source.timedMasks
        timedUnits = source.timedUnits
        maskPool = source.maskPool
        progressEvents = source.progressEvents
        processedEventCount = source.processedEventCount
        partialMasks = source.partialMasks
        baseOpacity = source.baseOpacity
        isHovered = source.isHovered
        blurRadius = source.blurRadius
        appliedBlurRadius = source.appliedBlurRadius
        cachedBlur = source.cachedBlur
        textHeight = source.textHeight
        super.init(layer: layer)
    }

    override var bounds: CGRect {
        didSet {
            guard bounds.size != oldValue.size else { return }
            timedUnits.forEach {
                $0.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            }
        }
    }

    func updateProgress(position: TimeInterval, animated: Bool = true) {
        guard position != lastProgressPosition else { return }
        lastProgressPosition = position
        guard hasTimedGlyphs else { return }
        applyProgress(position: position, animated: animated)
    }

    private func applyProgress(position: TimeInterval, animated: Bool) {
        guard let progressEvents else {
            for index in timedMasks.indices {
                timedMasks[index].update(at: position, pool: &maskPool)
            }
            timedUnits.forEach { $0.layer.setLifted(position >= $0.start, animated: animated) }
            return
        }

        // A steady frame touches only masks that are currently feathering. A seek
        // replays or reverses the crossed events, including overlapping timings.
        let crossedPreviousEvent = processedEventCount > 0
            && !(progressEvents[processedEventCount - 1].time <= position)
        let crossedNextEvent = processedEventCount < progressEvents.count
            && progressEvents[processedEventCount].time <= position
        if crossedPreviousEvent || crossedNextEvent {
            var lower = crossedNextEvent ? processedEventCount + 1 : 0
            var upper = crossedPreviousEvent ? processedEventCount - 1 : progressEvents.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if progressEvents[middle].time <= position {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            if crossedNextEvent {
                for event in progressEvents[processedEventCount..<lower] {
                    apply(event.change, advancing: true, animated: animated)
                }
            } else {
                for event in progressEvents[lower..<processedEventCount].reversed() {
                    apply(event.change, advancing: false, animated: animated)
                }
            }
            processedEventCount = lower
        }
        for index in partialMasks {
            timedMasks[index].update(at: position, pool: &maskPool)
        }
    }

    private func apply(_ change: ProgressEvent.Change, advancing: Bool, animated: Bool) {
        switch change {
        case .maskStarts(let index):
            if advancing {
                partialMasks.insert(index)
            } else {
                partialMasks.remove(index)
                timedMasks[index].update(fraction: 0, pool: &maskPool)
            }
        case .maskEnds(let index):
            if advancing {
                partialMasks.remove(index)
                timedMasks[index].update(fraction: 1, pool: &maskPool)
            } else {
                partialMasks.insert(index)
            }
        case .lift(let index):
            timedUnits[index].layer.setLifted(advancing, animated: animated)
        }
    }

    private func indexProgressEvents() {
        var events: [ProgressEvent] = []
        events.reserveCapacity(timedMasks.count * 2 + timedUnits.count)
        for (index, mask) in timedMasks.enumerated() {
            // At the exact start the lift has begun, but the mask is still empty.
            let firstVisibleTime = mask.start.nextUp
            events.append(ProgressEvent(time: firstVisibleTime, change: .maskStarts(index)))
            events.append(ProgressEvent(time: max(firstVisibleTime, mask.end), change: .maskEnds(index)))
        }
        for (index, unit) in timedUnits.enumerated() {
            events.append(ProgressEvent(time: unit.start, change: .lift(index)))
        }
        if events.allSatisfy({ $0.time.isFinite }) {
            progressEvents = events.sorted { $0.time < $1.time }
        }
    }

    func prepareForDisplay(timed: Bool, prewarm: Bool) {
        let upcomingLayer = prepareTextLayers()
        // An unsung row has the same text layout and color in a single layer.
        // Prepare the next row's glyphs off-tree to avoid a hitch when it becomes active.
        if timed || prewarm { prepareTimedGlyphs(using: upcomingLayer) }
        guard timed else {
            if prewarm {
                for unit in timedUnits where unit.layer.superlayer != nil {
                    unit.layer.removeAllAnimations()
                    unit.layer.removeFromSuperlayer()
                }
            } else {
                discardTimedGlyphs()
            }
            if upcomingLayer.superlayer == nil {
                insertSublayer(upcomingLayer, at: 0)
                upcomingLayer.prepareForDisplay()
            }
            return
        }
        if upcomingLayer.superlayer != nil { upcomingLayer.removeFromSuperlayer() }
        if let first = timedUnits.first, first.layer.superlayer == nil {
            timedUnits.forEach { addSublayer($0.layer) }
        }
    }

    private func prepareTextLayers() -> KaraokeTextLayer {
        if let upcomingLayer { return upcomingLayer }
        let layer = KaraokeTextLayer(
            text: originalText, width: bounds.width, height: originalHeight, scale: rasterizationScale
        )
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.isHidden = originalTextIsEmpty
        upcomingLayer = layer

        if let supplementaryText, let supplementaryHeight {
            let layer = KaraokeTextLayer(
                text: supplementaryText, width: bounds.width, height: supplementaryHeight, scale: rasterizationScale
            )
            layer.anchorPoint = .zero
            layer.position = CGPoint(x: 0, y: originalHeight + 5)
            addSublayer(layer)
            layer.prepareForDisplay()
            supplementaryLayer = layer
        }
        return layer
    }

    private func prepareTimedGlyphs(using source: KaraokeTextLayer) {
        guard !hasTimedGlyphs else { return }
        hasTimedGlyphs = true
        makeTimedGlyphs(self, source)
        indexProgressEvents()
        if let lastProgressPosition { applyProgress(position: lastProgressPosition, animated: false) }
        timedUnits.forEach { $0.layer.prepareForDisplay() }
    }

    func discardDisplayLayers() {
        discardTimedGlyphs()
        upcomingLayer?.removeFromSuperlayer()
        supplementaryLayer?.removeFromSuperlayer()
        upcomingLayer = nil
        supplementaryLayer = nil
    }

    private func discardTimedGlyphs() {
        guard hasTimedGlyphs else { return }
        for index in timedMasks.indices {
            timedMasks[index].detach()
        }
        timedUnits.forEach { $0.layer.removeFromSuperlayer() }
        timedUnits.removeAll()
        timedMasks.removeAll()
        maskPool.removeAll()
        progressEvents = nil
        processedEventCount = 0
        partialMasks.removeAll()
        hasTimedGlyphs = false
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateSoftening()
        animateOpacity(to: effectiveOpacity, duration: hovered ? 0.20 : 0.25)
    }

    private func updateSoftening() {
        let radius = isHovered || isHidden ? 0 : blurRadius
        guard appliedBlurRadius != radius else { return }
        appliedBlurRadius = radius
        let blurred = radius > 0
        if blurred {
            if cachedBlur?.radius != radius {
                cachedBlur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .map { (radius, $0) }
            }
            filters = cachedBlur.map { [$0.filter] }
        } else {
            filters = nil
        }
        // Reuse the filtered row while it moves or fades. Keep the active glyphs live.
        shouldRasterize = blurred
    }

    private var effectiveOpacity: Float {
        isHovered && !isHidden ? max(baseOpacity, 0.92) : baseOpacity
    }

    private func animateOpacity(to target: Float, duration: CFTimeInterval) {
        let current = presentation()?.opacity ?? opacity
        opacity = target
        removeAnimation(forKey: "lineOpacity")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(animation, forKey: "lineOpacity")
    }

    func setVisualState(
        opacity: Float,
        scale: CGFloat,
        blurRadius: CGFloat,
        hidden: Bool,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        baseOpacity = opacity
        self.blurRadius = blurRadius
        let targetOpacity = isHovered && !hidden ? max(baseOpacity, 0.92) : baseOpacity
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        if isHidden == hidden,
           abs(self.opacity - targetOpacity) < 0.001,
           CATransform3DEqualToTransform(transform, targetTransform) {
            updateSoftening()
            return
        }
        isHidden = hidden
        updateSoftening()
        let presented = animated ? presentation() : nil
        let oldOpacity = presented?.opacity ?? self.opacity
        let oldTransform = presented?.transform ?? transform
        self.opacity = targetOpacity
        transform = targetTransform
        guard animated else {
            removeAnimation(forKey: "lineOpacity")
            removeAnimation(forKey: "lineScale")
            return
        }

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = oldOpacity
        opacityAnimation.toValue = targetOpacity
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(opacityAnimation, forKey: "lineOpacity")

        if !CATransform3DEqualToTransform(oldTransform, targetTransform) {
            let scaleAnimation = CABasicAnimation(keyPath: "transform")
            scaleAnimation.fromValue = oldTransform
            scaleAnimation.toValue = targetTransform
            scaleAnimation.duration = duration
            scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            add(scaleAnimation, forKey: "lineScale")
        }
    }
}
