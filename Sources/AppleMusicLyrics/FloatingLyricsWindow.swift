import AppKit
import CoreImage
import QuartzCore
import CoreVideo

final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let canvas = LyricsCanvasView(frame: .zero)
    private let title = NSTextField(labelWithString: "Apple Music Lyrics")
    private let artist = NSTextField(labelWithString: "")
    private let background = GlassSurface()
    private let vinyl = VinylPlayerView(frame: .zero)
    private let controls = PlaybackControls(buttonWidth: 36, grouped: true)
    private let closeButton = WindowDotButton(color: .systemRed, symbol: "xmark", label: "关闭歌词窗口")
    private let lockButton = WindowDotButton(color: .systemYellow, symbol: "lock.fill", label: "锁定窗口位置")
    private let modeButton = WindowDotButton(color: .systemGreen, symbol: "arrow.up.left.and.arrow.down.right", label: "选择歌词窗口模式")
    private let modeMenu = NSMenu()
    private var restoringPosition = true
    private var currentState: PlayerState = .stopped
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.contentView = background
        background.content.addSubview(vinyl)
        for label in [title, artist] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            background.content.addSubview(label)
        }
        artist.textColor = .secondaryLabelColor
        background.content.addSubview(canvas)
        background.content.addSubview(controls)
        for button in [closeButton, lockButton, modeButton] {
            background.content.addSubview(button)
        }
        closeButton.onPress = { [weak self] in self?.setVisible(false) }
        lockButton.onPress = { [weak self] in
            AppPreferences.floatingPositionLocked.toggle()
            self?.applyPositionLock()
        }
        modeButton.onPress = { [weak self] in self?.showModeMenu() }
        for size in FloatingLyricsSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            modeMenu.addItem(item)
        }
        vinyl.onTogglePlayPause = { [weak self] in self?.onTogglePlayPause?() }
        controls.onPrevious = { [weak self] in self?.onPreviousTrack?() }
        controls.onToggle = { [weak self] in self?.onTogglePlayPause?() }
        controls.onNext = { [weak self] in self?.onNextTrack?() }
        canvas.onSeek = { [weak self] in self?.onSeek?($0) }
        applyPreferences()
        restorePosition()
        restoringPosition = false
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityChanged() { canvas.invalidateGeometry() }

    @objc private func screenChanged() { constrainToScreen() }

    func resetPlaybackClock() { canvas.resetPlaybackClock() }

    func applyPreferences() {
        let size = AppPreferences.floatingSize
        let oldFrame = panel.frame
        var frame = NSRect(origin: oldFrame.origin, size: size.dimensions)
        frame.origin.y += oldFrame.height - frame.height
        panel.setFrame(frame, display: true)
        vinyl.isHidden = size == .minimal
        controls.isHidden = size != .minimal
        if size == .minimal {
            title.alignment = .left
            artist.alignment = .left
            title.font = .systemFont(ofSize: 19, weight: .semibold)
            artist.font = .systemFont(ofSize: 13, weight: .medium)
            controls.frame = NSRect(x: frame.width - 36 - controls.width, y: frame.height - 75,
                                    width: controls.width, height: 34)
            let titleWidth = controls.frame.minX - 36 - 14
            title.frame = NSRect(x: 36, y: frame.height - 61, width: titleWidth, height: 24)
            artist.frame = NSRect(x: 36, y: frame.height - 80, width: titleWidth, height: 18)
            canvas.frame = NSRect(x: 14, y: 14, width: frame.width - 28, height: frame.height - 102)
        } else {
            let large = size == .large
            let vinylWidth: CGFloat = large ? 320 : 240
            vinyl.frame = NSRect(x: 12, y: 58, width: vinylWidth, height: frame.height - 70)
            title.alignment = .center
            artist.alignment = .center
            title.font = .systemFont(ofSize: large ? 17 : 15, weight: .semibold)
            artist.font = .systemFont(ofSize: large ? 13 : 12, weight: .medium)
            title.frame = NSRect(x: 22, y: 32, width: vinylWidth - 20, height: 22)
            artist.frame = NSRect(x: 22, y: 14, width: vinylWidth - 20, height: 17)
            canvas.frame = NSRect(x: vinylWidth + 4, y: 14, width: frame.width - vinylWidth - 20, height: frame.height - 28)
        }
        for (index, button) in [closeButton, lockButton, modeButton].enumerated() {
            button.frame = NSRect(x: 10 + CGFloat(index) * 20, y: frame.height - 28, width: 20, height: 23)
        }
        applyPositionLock()
        updateVinyl()
        background.updateOpacity()
        var behavior: NSWindow.CollectionBehavior = [.stationary]
        behavior.insert(AppPreferences.floatingLyricsSpaceBehavior == .allSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        if AppPreferences.floatingLyricsShowOverFullScreen {
            behavior.formUnion([.fullScreenAuxiliary, .canJoinAllApplications])
        }
        panel.collectionBehavior = behavior
        canvas.setSupplementaryLyrics(showTranslation: AppPreferences.floatingLyricsShowTranslation,
                                      showTransliteration: AppPreferences.floatingLyricsShowTransliteration)
        canvas.invalidateGeometry()
        constrainToScreen()
    }

    private func applyPositionLock() {
        let locked = AppPreferences.floatingPositionLocked
        panel.isMovable = !locked
        panel.isMovableByWindowBackground = !locked
        lockButton.marked = locked
        let label = locked ? "解锁窗口位置" : "锁定窗口位置"
        lockButton.toolTip = label
        lockButton.setAccessibilityLabel(label)
    }

    private func showModeMenu() {
        for item in modeMenu.items {
            item.state = item.representedObject as? String == AppPreferences.floatingSize.rawValue ? .on : .off
        }
        let anchor = NSPoint(x: modeButton.frame.minX, y: modeButton.frame.minY - 4)
        modeMenu.popUp(positioning: nil, at: anchor, in: background.content)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let size = FloatingLyricsSize(rawValue: value),
              size != AppPreferences.floatingSize else { return }
        AppPreferences.floatingSize = size
        NotificationCenter.default.post(name: AppPreferences.didChange, object: nil)
    }

    private func updateVinyl() {
        vinyl.update(playing: currentState == .playing, visible: isVisible && !vinyl.isHidden)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        canvas.setWindowVisible(visible)
        updateVinyl()
        onVisibilityChanged?(visible)
    }

    func apply(status: AppStatus) {
        currentState = status.track?.state ?? .stopped
        title.stringValue = status.track?.title ?? "Apple Music Lyrics"
        artist.stringValue = status.track?.artist ?? ""
        title.toolTip = status.track?.title
        artist.toolTip = status.track?.artist
        vinyl.allowsPlaybackControl = status.track != nil
        controls.update(status.track)
        updateVinyl()
        switch status {
        case .showing(let track, let lyrics, _):
            if lyrics.isSynced { canvas.update(track: track, lyrics: lyrics) }
            else { canvas.showPlainText(lyrics.plainText ?? "") }
        case .loadingLyrics:
            canvas.showMessage("正在读取歌词…")
        case .noLyrics:
            canvas.showMessage("打开音乐 App 的歌词以载入缓存")
        case .error(let message):
            canvas.showMessage(message)
        case .idle, .musicNotRunning, .stopped:
            canvas.showMessage("播放音乐，让歌词流动")
        }
    }

    func attachTranslationHost(_ host: NSView) {
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        background.content.addSubview(host)
    }

    func setArtwork(_ image: NSImage?) { vinyl.setArtwork(image) }

    func updateHighlight(for track: TrackInfo, lyrics: LyricsDocument) {
        currentState = track.state
        vinyl.allowsPlaybackControl = true
        controls.update(track)
        updateVinyl()
        canvas.update(track: track, lyrics: lyrics)
    }

    func windowDidMove(_ notification: Notification) {
        guard !restoringPosition else { return }
        guard let screen = panel.screen else { return }
        var frames = AppPreferences.floatingLyricsFramesByDisplay
        let id = displayID(screen)
        frames[id] = NSStringFromRect(panel.frame)
        AppPreferences.floatingLyricsFramesByDisplay = frames
        AppPreferences.floatingLyricsLastDisplay = id
    }

    private func displayID(_ screen: NSScreen) -> String {
        String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName)
    }

    private func restorePosition() {
        let frames = AppPreferences.floatingLyricsFramesByDisplay
        let screens = NSScreen.screens.sorted { displayID($0) == AppPreferences.floatingLyricsLastDisplay && displayID($1) != AppPreferences.floatingLyricsLastDisplay }
        for screen in screens {
            if let stored = frames[displayID(screen)] {
                panel.setFrameOrigin(NSRectFromString(stored).origin)
                constrainToScreen()
                return
            }
        }
        panel.center()
    }

    private func constrainToScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = max(area.minX, min(origin.x, area.maxX - panel.frame.width))
        origin.y = max(area.minY, min(origin.y, area.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }
}

private final class WindowDotButton: ActionButton {
    private let color: NSColor
    private let glyph: NSImage?
    private var hovered = false
    var marked = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, symbol: String, label: String) {
        self.color = color
        let style = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.72)]))
        glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(style)
        super.init()
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12))
        (isHighlighted ? color.blended(withFraction: 0.17, of: .black) ?? color : color).setFill()
        dot.fill()
        if hovered || marked, let glyph {
            let rect = NSRect(x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
}

private final class LyricsCanvasView: NSView {
    private struct PendingLyricClick {
        let lineIndex: Int
        let screenLocation: NSPoint
    }

    private enum AnimationSpec {
        static let lineStateDuration: CFTimeInterval = 0.33
        static let lineSpringMass: CGFloat = 1
        static let lineSpringStiffness: CGFloat = 140
        static let lineSpringDamping: CGFloat = 24
        static let manualScrollFollowDelay: TimeInterval = 4
        static let lineTapProgressFreezeDuration: TimeInterval = 0.55
        static let featherWidth: CGFloat = 10
        static let animationHeadstart: TimeInterval = 0
        static let clickDragThreshold: CGFloat = 5
    }

    private var layoutSize: NSSize { bounds.size }

    private var typographyScale: CGFloat { CGFloat(AppPreferences.fontScale) * (AppPreferences.floatingSize == .large ? 1.3 : 1) }

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
        let averageHeight: CGFloat
        if lineHeights.isEmpty {
            averageHeight = 39 * typographyScale
        } else {
            averageHeight = lineHeights.reduce(0, +) / CGFloat(lineHeights.count)
                + 5 * typographyScale
        }
        let rowsNeeded = Int(ceil(bounds.height * 0.62 / max(1, averageHeight))) + 1
        return min(18, max(5, rowsNeeded))
    }

    private var lines: [LyricLine] = []
    private var activeIndex: Int?
    private var message: String?
    private var plainText: String?

    private var lineCenters: [CGFloat] = []
    private var lineHeights: [CGFloat] = []
    private var geometryWidth: CGFloat = 0
    private var geometryScale: CGFloat = 0
    private var geometryLinesID: [String] = []

    private lazy var displayLink = DisplayLinkDriver { [weak self] in
        self?.updateLayerPresentation()
    }
    private var isWindowVisible = false
    private var showsTranslation = true
    private var showsTransliteration = true
    private var hoveredLineIndex: Int?
    private var pointerInside = false
    private var browsingIndex: Int?
    private var isManualScrolling = false
    private var autoFollowResumeDeadline: CFTimeInterval = 0
    private var manualScrollEndWorkItem: DispatchWorkItem?
    private var manualScrollResumeWorkItem: DispatchWorkItem?
    private var frozenPosition: TimeInterval?
    private var frozenPositionDeadline: CFTimeInterval = 0
    private var pendingLyricClick: PendingLyricClick?

    var onSeek: ((TimeInterval) -> Void)?

    private var basePosition: TimeInterval = 0
    private var sampledAt = CACurrentMediaTime()
    private var isPlaying = false

    private let edgeMask = CAGradientLayer()
    private let lyricsLayer = NoImplicitAnimationLayer()
    private var karaokeLayers: [KaraokeLineLayer] = []
    private var visualActiveIndex: Int?
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
        displayLink.stop()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        lyricsLayer.isGeometryFlipped = true
        layer?.addSublayer(lyricsLayer)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        resetLyricsLayerGeometry()
        CATransaction.commit()
        if (
                abs(geometryWidth - layoutSize.width) > 0.5
                    || abs(geometryScale - typographyScale) > 0.01
            ) {
            // AppKit forbids recursively rebuilding TextKit content from layout().
            // The next playback update performs it.
            geometryWidth = 0
            geometryScale = 0
        }
    }

    func setLyrics(_ document: LyricsDocument, track: TrackInfo) {
        let changed = document.lines != lines
        lines = document.lines
        message = nil
        plainText = nil
        updateClock(track)
        activeIndex = document.lineIndex(at: track.position)
        if changed {
            invalidateGeometry()
        }
        rebuildLayersIfNeeded()
        updateLayerPresentation(animateLineChange: false)
        updateTimerState()
        needsDisplay = true
    }

    func update(track: TrackInfo, lyrics: LyricsDocument) {
        if lyrics.lines != lines {
            setLyrics(lyrics, track: track)
            return
        }
        updateClock(track)
        rebuildLayersIfNeeded()
        updateLayerPresentation()
        updateTimerState()
    }

    func clear() {
        lines = []
        message = nil
        plainText = nil
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func showMessage(_ text: String) {
        lines = []
        plainText = nil
        message = text
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func showPlainText(_ text: String) {
        lines = []
        message = nil
        plainText = text
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func invalidateGeometry() {
        geometryWidth = 0
        geometryScale = 0
        rebuildLayersIfNeeded()
        updateLayerPresentation(animateLineChange: false)
        needsDisplay = true
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
        updateTimerState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // This view is transparent and layer-backed. Clear retained pixels so
        // a previously sung line cannot keep the next line fully highlighted.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        if let message {
            drawMessage(message)
            return
        }
        if let plainText {
            drawPlainText(plainText)
            return
        }
        // Synced lyrics are persistent sublayers and never redraw through AppKit.
    }

    private func rebuildLayersIfNeeded() {
        let ids = lines.map(\.id)
        let scale = typographyScale
        guard abs(geometryWidth - layoutSize.width) > 0.5
                || abs(geometryScale - scale) > 0.01
                || geometryLinesID != ids else { return }

        // Translations can arrive while the user is reading another part of the song.
        let browsedRow = geometryLinesID == ids ? browsingIndex : nil
        let browseOffset = browsedRow.map { index in
            (lyricsLayer.presentation()?.bounds.origin.y ?? lyricsLayer.bounds.origin.y) - scrollTarget(for: index)
        }
        geometryWidth = layoutSize.width
        geometryScale = scale
        geometryLinesID = ids
        let width = contentWidth
        var cursor: CGFloat = 0
        lineCenters = []
        lineHeights = []
        clearKaraokeLayers(preservingBrowse: browsedRow != nil)

        for (index, line) in lines.enumerated() {
            let fallbackEnd = index + 1 < lines.count
                ? max(line.time + 0.01, lines[index + 1].time)
                : max(line.time + 2, line.endTime)
            let lineLayer = KaraokeLineLayer(
                line: line,
                fallbackEnd: fallbackEnd,
                font: activeFont,
                supplementaryText: supplementaryText(for: line),
                width: width,
                contentsScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                featherWidth: AnimationSpec.featherWidth * scale
            )
            let height = max(40 * scale, lineLayer.textHeight + 18 * scale)
            lineHeights.append(height)
            lineCenters.append(cursor + height / 2)
            lineLayer.bounds = CGRect(x: 0, y: 0, width: width, height: lineLayer.textHeight)
            lineLayer.position = CGPoint(
                x: contentOriginX + width / 2,
                y: cursor + height / 2
            )
            lineLayer.isHidden = true
            lyricsLayer.addSublayer(lineLayer)
            karaokeLayers.append(lineLayer)
            cursor += height + 5 * scale
        }
        let contentHeight = max(0, cursor - 5 * scale)
        for index in karaokeLayers.indices {
            let mirroredCenter = contentHeight - lineCenters[index]
            lineCenters[index] = mirroredCenter
            karaokeLayers[index].position.y = mirroredCenter
        }
        if let browsedRow, let browseOffset {
            setScrollPosition(scrollTarget(for: browsedRow) + browseOffset)
            isScrollStateInitialized = true
        }
        lyricsLayer.isHidden = lines.isEmpty
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
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72),
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

    private func updateLayerPresentation(animateLineChange: Bool = true) {
        guard !lines.isEmpty else { return }
        rebuildLayersIfNeeded()

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
        var needsLineStateUpdate = lineChanged || visualActiveIndex != resolvedIndex
        let shouldResumeAutoFollow = !isManualScrolling
            && autoFollowResumeDeadline > 0
            && frameTime >= autoFollowResumeDeadline
        if shouldResumeAutoFollow {
            autoFollowResumeDeadline = 0
            visualScrollIndex = nil
            needsLineStateUpdate = true
        }
        let autoFollowSuppressed = browsingIndex != nil || autoFollowResumeDeadline > frameTime
        let needsScrollUpdate = visualScrollIndex != resolvedIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needsLineStateUpdate || !animateLineChange {
            updateLineStates(activeIndex: resolvedIndex, animated: animateLineChange)
            if !animateLineChange
                || previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) > 1 {
                for (index, lineLayer) in karaokeLayers.enumerated() where index != resolvedIndex {
                    lineLayer.updateProgress(
                        position: position + AnimationSpec.animationHeadstart,
                        animated: animateLineChange
                    )
                }
            } else if let previousIndex, previousIndex < karaokeLayers.count {
                karaokeLayers[previousIndex].updateProgress(
                    position: position + AnimationSpec.animationHeadstart,
                    animated: animateLineChange
                )
            }
        }
        if !autoFollowSuppressed && (needsScrollUpdate || !animateLineChange) {
            visualScrollIndex = resolvedIndex
            let isContinuousAdvance = previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) <= 1
            scroll(
                to: resolvedIndex,
                animated: animateLineChange && isContinuousAdvance
            )
        }
        karaokeLayers[resolvedIndex].updateProgress(
            position: position + AnimationSpec.animationHeadstart,
            animated: animateLineChange
        )
        CATransaction.commit()
    }

    private func updateLineStates(activeIndex: Int, animated: Bool) {
        let previous = visualActiveIndex
        visualActiveIndex = activeIndex
        let visibilityCenter = browsingIndex ?? activeIndex
        let visibleRadius = visibleLineRadius
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let browsing = browsingIndex != nil

        for index in karaokeLayers.indices {
            let lineLayer = karaokeLayers[index]
            let viewportDistance = abs(index - visibilityCenter)
            let wasRecentlyActive = previous.map { abs(index - $0) <= 1 } ?? false
            if viewportDistance <= visibleRadius + 2 || wasRecentlyActive {
                lineLayer.prepareForDisplay()
            }
            let opacity: Float
            if index == activeIndex {
                opacity = 1
            } else {
                opacity = increasedContrast || browsing
                    ? 0.85 : max(0.16, 0.76 - Float(viewportDistance) * 0.13)
            }
            lineLayer.setVisualState(
                opacity: opacity,
                scale: 1,
                softened: index != activeIndex && !increasedContrast && !browsing,
                hidden: viewportDistance > visibleRadius,
                animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duration: AnimationSpec.lineStateDuration
            )
        }
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
        karaokeLayers.forEach { $0.removeFromSuperlayer() }
        karaokeLayers = []
        visualActiveIndex = nil
        visualScrollIndex = nil
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        if !preservingBrowse { cancelManualScroll() }
        pendingLyricClick = nil
        autoFollowResumeDeadline = 0
        isScrollStateInitialized = false
        lyricsLayer.isHidden = true
    }

    private func supplementaryText(for line: LyricLine) -> String? {
        var values: [String] = []
        if showsTransliteration,
           let transliteration = line.transliteration,
           !transliteration.isEmpty {
            values.append(transliteration)
        }
        if showsTranslation,
           let translation = line.translation,
           !translation.isEmpty {
            values.append(translation)
        }
        return values.isEmpty ? nil : values.joined(separator: "\n")
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
        let targets = lineCenters.indices.map { scrollTarget(for: $0) }
        guard let minimum = targets.min(), let maximum = targets.max() else { return }
        let position = min(maximum, max(minimum, proposed))

        isScrollStateInitialized = true
        isManualScrolling = true
        autoFollowResumeDeadline = 0
        setScrollPosition(position)
        browsingIndex = nearestLineIndex(toScrollPosition: position)
        visualScrollIndex = nil
        updateHoveredLine(nil)
        if let activeIndex {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateLineStates(activeIndex: activeIndex, animated: false)
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
            self.updateLayerPresentation()
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
            updateLineStates(activeIndex: activeIndex, animated: true)
        }
    }

    private func nearestLineIndex(toScrollPosition position: CGFloat) -> Int? {
        guard !lineCenters.isEmpty else { return nil }
        return lineCenters.indices.min {
            abs(scrollTarget(for: $0) - position) < abs(scrollTarget(for: $1) - position)
        }
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
            screenLocation: NSEvent.mouseLocation
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if let pendingLyricClick,
           distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
                > AnimationSpec.clickDragThreshold {
            self.pendingLyricClick = nil
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
        let visibleBounds = lyricsLayer.presentation()?.bounds ?? lyricsLayer.bounds
        // The lyric container flips its sublayer geometry. Mirror through the
        // currently presented bounds so hover tracks the rendered row while a
        // spring scroll is in flight.
        let contentY = visibleBounds.maxY - point.y
        let candidates = karaokeLayers.indices.filter { !karaokeLayers[$0].isHidden }
        guard let nearest = candidates.min(by: {
            abs(lineCenters[$0] - contentY) < abs(lineCenters[$1] - contentY)
        }),
        abs(lineCenters[nearest] - contentY)
            <= lineHeights[nearest] * 0.5 + 6 * hitSlop else {
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

    private func activateTimer() {
        guard isPlaying, isWindowVisible else { return }
        displayLink.start()
    }

    private func updateTimerState() {
        if isPlaying, isWindowVisible, !lines.isEmpty {
            activateTimer()
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        displayLink.stop()
    }
}

private final class DisplayLinkDriver {
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

    func start() {
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
                  let link else { return }
            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    Unmanaged<DisplayLinkDriver>
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
}

private final class KaraokeTextLayer: NoImplicitAnimationLayer {
    struct GlyphFragment {
        let glyphRange: NSRange
        let rect: CGRect
    }

    private let storage: NSTextStorage
    private let textLayoutManager: NSLayoutManager
    private let textContainer: NSTextContainer

    let textHeight: CGFloat

    init(text: String, font: NSFont, color: NSColor, width: CGFloat, scale: CGFloat) {
        textLayoutManager = NSLayoutManager()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        storage = NSTextStorage(
            string: text.isEmpty ? "·" : text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        textContainer = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textLayoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(textLayoutManager)
        textLayoutManager.ensureLayout(for: textContainer)
        textHeight = ceil(max(1, textLayoutManager.usedRect(for: textContainer).height))

        super.init()
        contentsScale = scale
        drawsAsynchronously = false
        bounds = CGRect(x: 0, y: 0, width: width, height: textHeight)
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
        textHeight = source.textHeight
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        drawGlyphs(
            in: context,
            glyphRange: textLayoutManager.glyphRange(for: textContainer),
            at: .zero
        )
    }

    func drawGlyphs(in context: CGContext, glyphRange: NSRange, at origin: CGPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        textLayoutManager.drawGlyphs(
            forGlyphRange: glyphRange,
            at: origin
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func prepareForDisplay() {
        displayIfNeeded()
    }

    func fragments(for characterRange: NSRange) -> [GlyphFragment] {
        let glyphRange = textLayoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var result: [GlyphFragment] = []
        var glyphIndex = glyphRange.location
        let end = NSMaxRange(glyphRange)

        while glyphIndex < end {
            var lineRange = NSRange()
            _ = textLayoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange
            )
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
            let next = NSMaxRange(lineRange)
            if next <= glyphIndex { break }
            glyphIndex = next
        }
        return result
    }
}

private final class KaraokeGlyphFragmentLayer: NoImplicitAnimationLayer {
    private let source: KaraokeTextLayer
    private let glyphRange: NSRange
    private let textRect: CGRect

    init(source: KaraokeTextLayer, fragment: KaraokeTextLayer.GlyphFragment) {
        self.source = source
        glyphRange = fragment.glyphRange
        textRect = fragment.rect
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
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        source.drawGlyphs(
            in: context,
            glyphRange: glyphRange,
            at: CGPoint(x: -textRect.minX, y: -textRect.minY)
        )
    }

    func prepareForDisplay() {
        displayIfNeeded()
    }
}

private final class ProgressMaskSegmentLayer: NoImplicitAnimationLayer {
    private let fillLayer: NoImplicitAnimationLayer
    private let gradientLayer: CAGradientLayer
    private let segmentWidth: CGFloat
    private let featherWidth: CGFloat
    private var lastFraction: CGFloat = -1

    init(rect: CGRect, featherWidth: CGFloat) {
        fillLayer = NoImplicitAnimationLayer()
        gradientLayer = CAGradientLayer()
        segmentWidth = rect.width
        self.featherWidth = min(featherWidth, max(1, rect.width))
        super.init()
        frame = rect.insetBy(dx: 0, dy: -2)
        masksToBounds = true
        fillLayer.backgroundColor = NSColor.white.cgColor
        gradientLayer.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        gradientLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        addSublayer(fillLayer)
        addSublayer(gradientLayer)
        update(fraction: 0)
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
        lastFraction = source.lastFraction
        super.init(layer: layer)
    }

    func update(fraction: Double) {
        let fraction = CGFloat(min(1, max(0, fraction)))
        if (fraction == 0 && lastFraction == 0)
            || (fraction == 1 && lastFraction == 1) {
            return
        }
        lastFraction = fraction
        guard fraction > 0 else {
            isHidden = true
            return
        }
        isHidden = false
        if fraction >= 1 {
            fillLayer.frame = bounds
            gradientLayer.isHidden = true
            return
        }

        let width = segmentWidth * fraction
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, width - featherWidth),
            height: bounds.height
        )
        gradientLayer.isHidden = false
        gradientLayer.frame = CGRect(
            x: width - featherWidth,
            y: 0,
            width: featherWidth,
            height: bounds.height
        )
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
        let current = presentation()?.transform ?? transform
        transform = target

        guard animated else {
            removeAnimation(forKey: "syllableLift")
            return
        }
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
        let layer: ProgressMaskSegmentLayer
    }

    private struct TimedUnit {
        let start: TimeInterval
        let layer: TimedGlyphUnitLayer
    }

    private let upcomingLayer: KaraokeTextLayer
    private let highlightedLayer: KaraokeTextLayer
    private let supplementaryLayer: KaraokeTextLayer?
    private let ranges: [TimedRange]
    private var timedMasks: [TimedMask] = []
    private var timedUnits: [TimedUnit] = []
    private var baseOpacity: Float = 1
    private var isHovered = false
    private var softensText = false

    let textHeight: CGFloat

    init(
        line: LyricLine,
        fallbackEnd: TimeInterval,
        font: NSFont,
        supplementaryText: String?,
        width: CGFloat,
        contentsScale: CGFloat,
        featherWidth: CGFloat
    ) {
        let text = line.words.isEmpty ? line.text : line.words.map(\.text).joined()
        upcomingLayer = KaraokeTextLayer(
            text: text,
            font: font,
            color: NSColor.labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.75 : 0.52),
            width: width,
            scale: contentsScale
        )
        highlightedLayer = KaraokeTextLayer(
            text: text,
            font: font,
            color: NSColor.labelColor.withAlphaComponent(0.98),
            width: width,
            scale: contentsScale
        )
        if let supplementaryText, !supplementaryText.isEmpty {
            supplementaryLayer = KaraokeTextLayer(
                text: supplementaryText,
                font: NSFont.systemFont(ofSize: max(11, font.pointSize * 0.80), weight: .regular),
                color: NSColor.secondaryLabelColor,
                width: width,
                scale: contentsScale
            )
        } else {
            supplementaryLayer = nil
        }
        textHeight = upcomingLayer.textHeight
            + (supplementaryLayer.map { 5 + $0.textHeight } ?? 0)

        var location = 0
        var built: [TimedRange] = []
        if line.words.isEmpty {
            let length = (text as NSString).length
            if length > 0 {
                built.append(
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
                    built.append(
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
        ranges = built
        super.init()
        isGeometryFlipped = true
        cornerRadius = 6

        if let supplementaryLayer {
            supplementaryLayer.anchorPoint = .zero
            supplementaryLayer.position = CGPoint(x: 0, y: upcomingLayer.textHeight + 5)
            addSublayer(supplementaryLayer)
        }

        for range in ranges {
            let characterRanges = composedCharacterRanges(
                in: text,
                range: range.characterRange
            )
            let visualRanges = characterRanges.isEmpty
                ? [range.characterRange]
                : characterRanges
            let fragmentPairs = visualRanges.map { characterRange in
                (
                    characterRange,
                    upcomingLayer.fragments(for: characterRange),
                    highlightedLayer.fragments(for: characterRange)
                )
            }
            let totalWidth = fragmentPairs.reduce(CGFloat(0)) { result, pair in
                result + pair.1.reduce(CGFloat(0)) { $0 + $1.rect.width }
            }
            let duration = max(0.01, range.end - range.start)
            var consumedWidth: CGFloat = 0
            for (_, upcomingFragments, highlightedFragments) in fragmentPairs {
                let unitWidth = upcomingFragments.reduce(CGFloat(0)) {
                    $0 + $1.rect.width
                }
                guard unitWidth > 0 else { continue }
                let unitStart = range.start
                    + duration * TimeInterval(consumedWidth / max(1, totalWidth))
                let unitEnd = range.start
                    + duration * TimeInterval(
                        (consumedWidth + unitWidth) / max(1, totalWidth)
                    )
                consumedWidth += unitWidth

                let unit = TimedGlyphUnitLayer(
                    size: CGSize(width: width, height: textHeight),
                    lift: max(1.5, font.pointSize * 0.12)
                )
                var fragmentWidth: CGFloat = 0
                for (upcomingFragment, highlightedFragment) in zip(
                    upcomingFragments,
                    highlightedFragments
                ) where upcomingFragment.rect.width > 0 {
                    let fragmentStart = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)
                    fragmentWidth += upcomingFragment.rect.width
                    let fragmentEnd = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)

                    let upcomingSlice = KaraokeGlyphFragmentLayer(
                        source: upcomingLayer,
                        fragment: upcomingFragment
                    )
                    let highlightedSlice = KaraokeGlyphFragmentLayer(
                        source: highlightedLayer,
                        fragment: highlightedFragment
                    )
                    let mask = ProgressMaskSegmentLayer(
                        rect: CGRect(origin: .zero, size: highlightedFragment.rect.size),
                        featherWidth: featherWidth
                    )
                    highlightedSlice.mask = mask
                    unit.addFragment(upcomingSlice)
                    unit.addFragment(highlightedSlice)
                    timedMasks.append(
                        TimedMask(start: fragmentStart, end: fragmentEnd, layer: mask)
                    )
                }
                addSublayer(unit)
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
        upcomingLayer = source.upcomingLayer
        highlightedLayer = source.highlightedLayer
        supplementaryLayer = source.supplementaryLayer
        ranges = source.ranges
        timedMasks = source.timedMasks
        timedUnits = source.timedUnits
        baseOpacity = source.baseOpacity
        isHovered = source.isHovered
        softensText = source.softensText
        textHeight = source.textHeight
        super.init(layer: layer)
    }

    override var bounds: CGRect {
        didSet {
            timedUnits.forEach {
                $0.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            }
        }
    }

    func updateProgress(position: TimeInterval, animated: Bool = true) {
        for timedMask in timedMasks {
            let duration = max(0.01, timedMask.end - timedMask.start)
            timedMask.layer.update(
                fraction: (position - timedMask.start) / duration
            )
        }
        for timedUnit in timedUnits {
            timedUnit.layer.setLifted(
                position >= timedUnit.start,
                animated: animated
            )
        }
    }

    func prepareForDisplay() {
        timedUnits.forEach { $0.layer.prepareForDisplay() }
        supplementaryLayer?.prepareForDisplay()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateSoftening()
        animateOpacity(to: effectiveOpacity, duration: hovered ? 0.20 : 0.25)
    }

    private func updateSoftening() {
        let shouldBlur = softensText && !isHovered && !isHidden
        let hasBlur = !(filters?.isEmpty ?? true)
        guard shouldBlur != hasBlur else { return }
        filters = shouldBlur
            ? CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.1]).map { [$0] }
            : nil
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
        softened: Bool,
        hidden: Bool,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        baseOpacity = opacity
        softensText = softened
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
        let oldOpacity = presentation()?.opacity ?? self.opacity
        let oldTransform = presentation()?.transform ?? transform
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

        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = oldTransform
        scaleAnimation.toValue = transform
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(scaleAnimation, forKey: "lineScale")
    }
}
