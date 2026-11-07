import AppKit
import QuartzCore
import CoreVideo

final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let canvas = LyricsCanvasView(frame: .zero)
    private let title = NSTextField(labelWithString: "Apple Music Lyrics")
    private let background = NSVisualEffectView()
    var onSeek: ((TimeInterval) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 24
        background.layer?.masksToBounds = true
        panel.contentView = background
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        background.addSubview(title)
        background.addSubview(canvas)
        canvas.onSeek = { [weak self] in self?.onSeek?($0) }
        applyPreferences()
        restorePosition()
    }

    func applyPreferences() {
        let oldFrame = panel.frame
        var frame = NSRect(origin: oldFrame.origin, size: AppPreferences.floatingSize.dimensions)
        frame.origin.y += oldFrame.height - frame.height
        panel.setFrame(frame, display: true)
        title.frame = NSRect(x: 24, y: frame.height - 42, width: frame.width - 48, height: 20)
        canvas.frame = NSRect(x: 16, y: 12, width: frame.width - 32, height: frame.height - 58)
        background.alphaValue = CGFloat(AppPreferences.floatingLyricsOpacity)
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

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        canvas.setWindowVisible(visible)
        onVisibilityChanged?(visible)
    }

    func apply(status: AppStatus) {
        switch status {
        case .showing(let track, let lyrics, _):
            title.stringValue = track.displayName
            if lyrics.isSynced { canvas.update(track: track, lyrics: lyrics) }
            else { canvas.showPlainText(lyrics.plainText ?? "") }
        case .loadingLyrics(let track):
            title.stringValue = track.displayName
            canvas.showMessage("正在读取歌词…")
        case .noLyrics(let track):
            title.stringValue = track.displayName
            canvas.showMessage("打开音乐 App 的歌词以载入缓存")
        case .error(let message):
            canvas.showMessage(message)
        case .idle, .musicNotRunning, .stopped:
            title.stringValue = "Apple Music Lyrics"
            canvas.showMessage("播放音乐，让歌词流动")
        }
    }

    func updateHighlight(for track: TrackInfo, lyrics: LyricsDocument) {
        canvas.update(track: track, lyrics: lyrics)
    }

    func windowDidMove(_ notification: Notification) {
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
        static let lineScrollHeadstart: TimeInterval = 0.5
        static let manualScrollFollowDelay: TimeInterval = 3
        static let lineTapProgressFreezeDuration: TimeInterval = 0.55
        static let featherWidth: CGFloat = 10
        static let animationHeadstart: TimeInterval = 0
        static let clickDragThreshold: CGFloat = 5
    }

    private var layoutSize: NSSize {
        guard isLiveResizing else { return bounds.size }
        return NSSize(
            width: max(1, (bounds.width / 12).rounded() * 12),
            height: max(1, (bounds.height / 10).rounded() * 10)
        )
    }

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
        .systemFont(ofSize: 19 * typographyScale, weight: .semibold)
    }

    // The lyric container flips its sublayer geometry, so the content-space
    // ratio is the inverse of the desired visual position.
    private var scrollFocusRatio: CGFloat {
        0.50
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
    private let isLiveResizing = false
    private var isWindowMoving = false
    private var isWindowVisible = false
    private var showsTranslation = true
    private var showsTransliteration = true
    private var hoveredLineIndex: Int?
    private var pointerInside = false
    private var browsingIndex: Int?
    private var isManualScrolling = false
    private var autoFollowResumeDeadline: CFTimeInterval = 0
    private var manualScrollEndWorkItem: DispatchWorkItem?
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
        displayLink.stop()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
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
        if !isLiveResizing
            && (
                abs(geometryWidth - layoutSize.width) > 0.5
                    || abs(geometryScale - typographyScale) > 0.01
            ) {
            // AppKit forbids recursively rebuilding TextKit content from layout().
            // The next playback update or resize delegate callback performs it.
            geometryWidth = 0
            geometryScale = 0
            geometryLinesID = []
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
        geometryLinesID = []
        if !isLiveResizing {
            rebuildLayersIfNeeded()
            updateLayerPresentation(animateLineChange: false)
        }
        needsDisplay = true
    }

    private func resetLyricsLayerGeometry() {
        lyricsLayer.transform = CATransform3DIdentity
        var layerBounds = lyricsLayer.bounds
        layerBounds.size = bounds.size
        lyricsLayer.bounds = layerBounds
        lyricsLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func beginWindowMove() {
        guard !isWindowMoving else { return }
        pendingLyricClick = nil
        isWindowMoving = true
        stopTimer()
    }

    func endWindowMove() {
        guard isWindowMoving else { return }
        isWindowMoving = false
        updateTimerState()
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

        geometryWidth = layoutSize.width
        geometryScale = scale
        geometryLinesID = ids
        let width = contentWidth
        var cursor: CGFloat = 0
        lineCenters = []
        lineHeights = []
        clearKaraokeLayers()

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
            let height = max(34 * scale, lineLayer.textHeight + 12 * scale)
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

    private func updateClock(_ track: TrackInfo) {
        let now = CACurrentMediaTime()
        if let frozenPosition,
           abs(track.position - frozenPosition) < 0.8 {
            self.frozenPosition = nil
            frozenPositionDeadline = 0
        }
        let estimated = interpolatedPosition(at: now)
        let error = track.position - estimated
        if isPlaying, abs(error) < 0.75 {
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
        if !isLiveResizing {
            rebuildLayersIfNeeded()
        }

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
        let anticipatedIndex = lineIndex(
            at: position + AnimationSpec.lineScrollHeadstart
        ) ?? resolvedIndex
        let scrollIndex = min(resolvedIndex + 1, anticipatedIndex)
        let shouldResumeAutoFollow = !isManualScrolling
            && autoFollowResumeDeadline > 0
            && frameTime >= autoFollowResumeDeadline
        if shouldResumeAutoFollow {
            autoFollowResumeDeadline = 0
            browsingIndex = nil
            visualScrollIndex = nil
            needsLineStateUpdate = true
        }
        let autoFollowSuppressed = isManualScrolling || autoFollowResumeDeadline > frameTime
        let needsScrollUpdate = visualScrollIndex != scrollIndex

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
            visualScrollIndex = scrollIndex
            let isContinuousAdvance = previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) <= 1
            scroll(
                to: scrollIndex,
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
                opacity = max(0.10, 0.68 - Float(viewportDistance) * 0.10)
            }
            lineLayer.setVisualState(
                opacity: opacity,
                scale: 1,
                hidden: viewportDistance > visibleRadius,
                animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duration: AnimationSpec.lineStateDuration
            )
        }
    }

    private func scroll(to index: Int, animated: Bool) {
        let target = lineCenters[index] - bounds.height * scrollFocusRatio
        if !isScrollStateInitialized {
            isScrollStateInitialized = true
            setScrollPosition(target)
            return
        }

        guard animated,
              AppPreferences.smoothScrolling,
              isPlaying,
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

    private func clearKaraokeLayers() {
        karaokeLayers.forEach { $0.removeFromSuperlayer() }
        karaokeLayers = []
        visualActiveIndex = nil
        visualScrollIndex = nil
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        browsingIndex = nil
        isManualScrolling = false
        pendingLyricClick = nil
        autoFollowResumeDeadline = 0
        manualScrollEndWorkItem?.cancel()
        manualScrollEndWorkItem = nil
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
        guard !lines.isEmpty,
              !isLiveResizing else {
            super.scrollWheel(with: event)
            return
        }

        let current = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let proposed = current + event.scrollingDeltaY * multiplier
        let targets = lineCenters.map { $0 - bounds.height * scrollFocusRatio }
        guard let minimum = targets.min(), let maximum = targets.max() else { return }
        let position = min(maximum, max(minimum, proposed))

        isScrollStateInitialized = true
        isManualScrolling = true
        autoFollowResumeDeadline = CACurrentMediaTime()
            + AnimationSpec.manualScrollFollowDelay
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
    }

    private func finishManualScroll() {
        manualScrollEndWorkItem = nil
        guard isManualScrolling else { return }
        isManualScrolling = false
        let visiblePosition = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        guard let index = nearestLineIndex(toScrollPosition: visiblePosition) else { return }
        browsingIndex = index
        autoFollowResumeDeadline = CACurrentMediaTime()
            + AnimationSpec.manualScrollFollowDelay
        scroll(to: index, animated: true)
        if let activeIndex {
            updateLineStates(activeIndex: activeIndex, animated: true)
        }
    }

    private func nearestLineIndex(toScrollPosition position: CGFloat) -> Int? {
        guard !lineCenters.isEmpty else { return nil }
        let contentFocus = position + bounds.height * scrollFocusRatio
        return lineCenters.indices.min {
            abs(lineCenters[$0] - contentFocus) < abs(lineCenters[$1] - contentFocus)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerInside, !isLiveResizing else {
            updateHoveredLine(nil)
            return
        }
        updateHoveredLine(lyricLineIndex(at: event, hitSlop: 0.7))
    }

    override func mouseExited(with event: NSEvent) {
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
        guard !isWindowMoving,
              !isLiveResizing,
              distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
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
            "Lyric click; index=\(selectedIndex); time=\(target); text=\(lines[selectedIndex].text)"
        )
        let now = CACurrentMediaTime()
        frozenPosition = target
        frozenPositionDeadline = now + AnimationSpec.lineTapProgressFreezeDuration
        basePosition = target
        sampledAt = now
        browsingIndex = nil
        isManualScrolling = false
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
        guard isPlaying,
              isWindowVisible,
              !isWindowMoving else { return }
        displayLink.start()
    }

    private func updateTimerState() {
        if isPlaying, isWindowVisible, !isWindowMoving, !lines.isEmpty {
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
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1
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
            color: NSColor.labelColor.withAlphaComponent(0.30),
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
        animateOpacity(to: effectiveOpacity, duration: hovered ? 0.20 : 0.25)
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
        hidden: Bool,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        baseOpacity = opacity
        let targetOpacity = isHovered && !hidden ? max(baseOpacity, 0.92) : baseOpacity
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        if isHidden == hidden,
           abs(self.opacity - targetOpacity) < 0.001,
           CATransform3DEqualToTransform(transform, targetTransform) {
            return
        }
        isHidden = hidden
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
