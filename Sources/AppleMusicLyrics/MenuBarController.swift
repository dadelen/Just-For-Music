import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 258)
    private let menu = NSMenu()
    private let statusView = NSView()
    private let lyricButton = ActionButton()
    private let previousButton = ActionButton()
    private let playButton = ActionButton()
    private let nextButton = ActionButton()
    private let karaokeTitleView = KaraokeStatusTitleView()
    private let playerView = MenuPlayerView()
    private var viewportWidth: CGFloat = 180
    var onSettings: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onOpenMusic: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        playerView.onSeek = { [weak self] in self?.onSeek?($0) }
        playerView.onPreviousTrack = { [weak self] in self?.onPreviousTrack?() }
        playerView.onTogglePlayPause = { [weak self] in self?.onTogglePlayPause?() }
        playerView.onNextTrack = { [weak self] in self?.onNextTrack?() }
        playerView.onOpenMusic = { [weak self] in self?.onOpenMusic?() }
        let playerItem = NSMenuItem()
        playerItem.view = playerView
        menu.addItem(playerItem)
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 50))
        let settings = ActionButton(title: "设置") { [weak self] in
            self?.menu.cancelTracking()
            DispatchQueue.main.async { self?.onSettings?() }
        }
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        let quit = ActionButton(title: "退出") { [weak self] in self?.onQuit?() }
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.imagePosition = .imageLeading
        settings.frame = NSRect(x: 12, y: 8, width: 202, height: 34)
        quit.frame = NSRect(x: 226, y: 8, width: 202, height: 34)
        footer.addSubview(settings)
        footer.addSubview(quit)
        let footerItem = NSMenuItem()
        footerItem.view = footer
        menu.addItem(footerItem)
        configureStatusItem()
    }

    func setArtwork(_ image: NSImage?) { playerView.setArtwork(image) }

    func resetPlaybackClock() { karaokeTitleView.deactivate() }

    func updateKaraokeProgress(track: TrackInfo, lyrics: LyricsDocument) {
        playerView.update(track: track)
        updateControls(track)
        if let line = lyrics.line(at: track.position) { setKaraokeTitle(line: line, track: track) }
    }

    func apply(status: AppStatus) {
        updateControls(status.track)
        switch status {
        case .showing(let track, let lyrics, _):
            playerView.update(track: track)
            if let line = lyrics.line(at: track.position) { setKaraokeTitle(line: line, track: track) }
            else { setTitle(track.title) }
        case .loadingLyrics(let track), .noLyrics(let track):
            playerView.update(track: track)
            setTitle(track.title)
        case .error:
            playerView.update(track: nil, message: "请检查设置中的诊断信息")
            setTitle("音乐连接中断")
        case .idle, .stopped, .musicNotRunning:
            playerView.update(track: nil, message: "打开音乐 App，开始播放")
            setTitle("♫ Music")
        }
    }

    private func updateControls(_ track: TrackInfo?) {
        for control in [previousButton, playButton, nextButton] { control.isEnabled = track != nil }
        playButton.setSymbol(track?.state == .playing ? "pause.fill" : "play.fill", label: track?.state == .playing ? "暂停" : "播放")
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        statusView.wantsLayer = true
        statusView.layer?.masksToBounds = true
        button.addSubview(statusView)
        for view in [lyricButton, previousButton, playButton, nextButton] { statusView.addSubview(view) }
        lyricButton.addSubview(karaokeTitleView)
        lyricButton.onPress = { [weak self] in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.statusView.bounds.height + 3), in: self.statusView)
        }
        previousButton.setSymbol("backward.fill", label: "上一首")
        playButton.setSymbol("play.fill", label: "播放")
        nextButton.setSymbol("forward.fill", label: "下一首")
        previousButton.onPress = { [weak self] in self?.onPreviousTrack?() }
        playButton.onPress = { [weak self] in self?.onTogglePlayPause?() }
        nextButton.onPress = { [weak self] in self?.onNextTrack?() }
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAppearance), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reloadAppearance()
    }

    @objc func reloadAppearance() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let mode = AppPreferences.statusBarMode
        let constrained = (screen?.auxiliaryTopRightArea?.width ?? 0) > 0 || (screen?.frame.width ?? 1440) < 1500
        viewportWidth = mode == .compact || (mode == .automatic && constrained) ? 112 : 180
        let iconOnly = mode == .icon
        let height = NSStatusBar.system.thickness
        let width = iconOnly ? height : viewportWidth + 78
        statusItem.length = width
        statusView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        lyricButton.frame = NSRect(x: 0, y: 0, width: iconOnly ? width : viewportWidth, height: height)
        karaokeTitleView.frame = lyricButton.bounds
        karaokeTitleView.isHidden = iconOnly || karaokeTitleView.isHidden
        for (index, control) in [previousButton, playButton, nextButton].enumerated() {
            control.isHidden = iconOnly
            control.frame = NSRect(x: viewportWidth + CGFloat(index) * 26, y: 0, width: 26, height: height)
        }
        if iconOnly { lyricButton.setSymbol("music.note", label: "打开播放器") }
        else { lyricButton.image = nil }
        karaokeTitleView.reloadColors()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setTitle(_ title: String) {
        karaokeTitleView.deactivate()
        karaokeTitleView.isHidden = true
        lyricButton.title = AppPreferences.statusBarMode == .icon ? "" : title
        lyricButton.setAccessibilityLabel("打开播放器，" + title)
    }

    private func setKaraokeTitle(line: LyricLine, track: TrackInfo) {
        guard AppPreferences.statusBarMode != .icon else { return }
        lyricButton.title = ""
        lyricButton.setAccessibilityLabel("打开播放器，" + line.text)
        _ = karaokeTitleView.update(line: line, track: track)
        karaokeTitleView.isHidden = false
    }

}

private final class CompactSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { 10 }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        let range = maxValue - minValue
        let fraction = range > 0 ? CGFloat((doubleValue - minValue) / range) : 0
        guard fraction > 0 else { return }
        var filled = track
        filled.size.width = max(track.height, track.width * min(1, max(0, fraction)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 10
        let compactRect = NSRect(
            x: knobRect.midX - diameter / 2,
            y: knobRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: compactRect).fill()
    }
}

private final class MenuPlayerView: NSView {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Apple Music Lyrics")
    private let subtitleLabel = NSTextField(labelWithString: "未播放歌曲")
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")


    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onOpenMusic: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 440, height: 156)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 156))
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
        artworkView.layer?.cornerRadius = 16
        artworkView.layer?.masksToBounds = true
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        setArtworkPlaceholder()

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.alignment = .center
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

        configureButton(
            previousButton,
            symbol: "backward.fill",
            toolTip: "上一首",
            action: #selector(previousTrack),
            pointSize: 16
        )
        configureButton(
            playPauseButton,
            symbol: "play.fill",
            toolTip: "播放",
            action: #selector(togglePlayPause),
            pointSize: 19
        )
        configureButton(
            nextButton,
            symbol: "forward.fill",
            toolTip: "下一首",
            action: #selector(nextTrack),
            pointSize: 16
        )

        let controls = NSStackView(views: [previousButton, playPauseButton, nextButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .equalSpacing
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.cell = CompactSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.sliderType = .linear
        slider.controlSize = .small
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(seek(_:))
        slider.toolTip = "播放进度"

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        remainingLabel.alignment = .right

        addSubview(artworkView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(controls)
        addSubview(slider)
        addSubview(elapsedLabel)
        addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            artworkView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            controls.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            controls.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            controls.heightAnchor.constraint(equalToConstant: 30),

            slider.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),

            elapsedLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: slider.bottomAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            remainingLabel.topAnchor.constraint(equalTo: slider.bottomAnchor)
        ])
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        toolTip: String,
        action: Selector,
        pointSize: CGFloat = 18
    ) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: toolTip
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = NSColor.labelColor.withAlphaComponent(0.84)
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: button === playPauseButton ? 40 : 34),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    func update(track: TrackInfo?, message: String? = nil) {
        guard let track else {
            titleLabel.stringValue = "Apple Music Lyrics"
            subtitleLabel.stringValue = message ?? "未播放歌曲"
            setArtworkPlaceholder()
            for button in [previousButton, playPauseButton, nextButton] {
                button.isEnabled = false
            }
            slider.isEnabled = false
            slider.doubleValue = 0
            elapsedLabel.stringValue = "0:00"
            remainingLabel.stringValue = "-0:00"
            return
        }

        titleLabel.stringValue = track.title
        if track.artist.isEmpty {
            subtitleLabel.stringValue = track.album
        } else if track.album.isEmpty {
            subtitleLabel.stringValue = track.artist
        } else {
            subtitleLabel.stringValue = "\(track.artist) · \(track.album)"
        }

        for button in [previousButton, playPauseButton, nextButton] {
            button.isEnabled = true
        }
        let isPlaying = track.state == .playing
        let playPauseToolTip = isPlaying ? "暂停" : "播放"
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: playPauseToolTip
        )?.withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        playPauseButton.toolTip = playPauseToolTip

        let duration = max(0, track.duration)
        let position = min(duration, max(0, track.position))
        slider.isEnabled = duration > 0
        slider.maxValue = max(1, duration)
        slider.doubleValue = position
        elapsedLabel.stringValue = formatTime(position)
        remainingLabel.stringValue = "-" + formatTime(max(0, duration - position))

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
        guard let image else { setArtworkPlaceholder(); return }
        artworkView.image = image
        artworkView.contentTintColor = nil
        artworkView.layer?.backgroundColor = nil
    }

    @objc private func previousTrack(_ sender: Any?) {
        onPreviousTrack?()
    }

    @objc private func openMusic(_ sender: Any?) {
        onOpenMusic?()
    }

    @objc private func togglePlayPause(_ sender: Any?) {
        onTogglePlayPause?()
    }

    @objc private func nextTrack(_ sender: Any?) {
        onNextTrack?()
    }

    @objc private func seek(_ sender: NSSlider) {
        onSeek?(sender.doubleValue)
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

    private struct PreviousLine {
        let text: String
        let segments: [Segment]
        let prefixLength: Int
        let prefixWidth: CGFloat
        let originX: CGFloat
        let startedAt: CFTimeInterval
    }

    private static let lineTransitionDuration: CFTimeInterval = 0.33
    private let font = NSFont.menuBarFont(ofSize: 13)
    private var displayText = ""
    private var segments: [Segment] = []
    private var prefixLength = 0
    private var basePosition: TimeInterval = 0
    private var sampledAt: CFTimeInterval = 0
    private var isPlaying = false
    private var displayTimer: Timer?
    private var currentLineID: String?
    private var renderedOriginX: CGFloat?
    private var lastDrawTime: CFTimeInterval = 0
    private var prefixWidth: CGFloat = 0
    private var previousLine: PreviousLine?
    private var renderedLine: LyricLine?
    private var activeColor = AppPreferences.menuBarLyricsActiveColor
    private var inactiveColor = AppPreferences.menuBarLyricsInactiveColor

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        displayTimer?.invalidate()
    }

    func update(line: LyricLine, track: TrackInfo) -> String {
        let now = CACurrentMediaTime()
        let estimated = interpolatedPosition(at: now)
        if currentLineID != line.id {
            if currentLineID != nil,
               !displayText.isEmpty,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let textWidth = measuredWidth(of: displayText)
                previousLine = PreviousLine(
                    text: displayText,
                    segments: segments,
                    prefixLength: prefixLength,
                    prefixWidth: prefixWidth,
                    originX: renderedOriginX ?? horizontalOrigin(
                        textWidth: textWidth,
                        position: estimated,
                        segments: segments,
                        prefixWidth: prefixWidth
                    ),
                    startedAt: now
                )
            } else {
                previousLine = nil
            }
            currentLineID = line.id
            renderedOriginX = nil
            lastDrawTime = now
        }
        let error = track.position - estimated
        if isPlaying, track.state == .playing, abs(error) < 0.75 {
            // Small sample corrections should not become visible motion.
            basePosition = estimated + error * 0.06
        } else {
            basePosition = track.position
        }
        sampledAt = now
        isPlaying = track.state == .playing

        if renderedLine != line {
            rebuildDisplay(line: line)
            renderedLine = line
        }
        if isPlaying || previousLine != nil {
            activateTimer()
        } else {
            stopTimer()
        }
        needsDisplay = true
        return displayText
    }

    func deactivate() {
        isPlaying = false
        stopTimer()
        displayText = ""
        segments = []
        currentLineID = nil
        renderedLine = nil
        renderedOriginX = nil
        previousLine = nil
    }

    func reloadColors() {
        activeColor = AppPreferences.menuBarLyricsActiveColor
        inactiveColor = AppPreferences.menuBarLyricsInactiveColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !displayText.isEmpty else { return }

        let textSize = NSSize(
            width: measuredWidth(of: displayText),
            height: measuredHeight(of: displayText)
        )
        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        let targetOriginX = horizontalOrigin(
            textWidth: textSize.width,
            position: position,
            segments: segments,
            prefixWidth: prefixWidth
        )
        let origin = NSPoint(
            x: smoothedOrigin(target: targetOriginX, at: now),
            y: floor((bounds.height - textSize.height) / 2)
        )

        if let previousLine {
            let elapsed = now - previousLine.startedAt
            let linearProgress = min(1, max(0, elapsed / Self.lineTransitionDuration))
            let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
            drawLine(
                text: previousLine.text,
                segments: previousLine.segments,
                prefixLength: previousLine.prefixLength,
                prefixWidth: previousLine.prefixWidth,
                position: position,
                origin: NSPoint(
                    x: previousLine.originX,
                    y: floor((bounds.height - measuredHeight(of: previousLine.text)) / 2)
                ),
                alpha: 1 - progress
            )
            drawLine(
                text: displayText,
                segments: segments,
                prefixLength: prefixLength,
                prefixWidth: prefixWidth,
                position: position,
                origin: origin,
                alpha: progress
            )
            if linearProgress >= 1 {
                self.previousLine = nil
                if !isPlaying {
                    stopTimer()
                }
            }
        } else {
            drawLine(
                text: displayText,
                segments: segments,
                prefixLength: prefixLength,
                prefixWidth: prefixWidth,
                position: position,
                origin: origin,
                alpha: 1
            )
        }
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
        guard alpha > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let upcoming = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? inactiveColor.withAlphaComponent(max(0.72, inactiveColor.alphaComponent)) : inactiveColor,
                .paragraphStyle: paragraph
            ]
        )
        let sung = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: activeColor,
                .paragraphStyle: paragraph
            ]
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        let timedGlyphs = segments.flatMap(\.glyphs)
        guard !timedGlyphs.isEmpty else {
            upcoming.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if prefixLength > 0 {
            draw(attributed: upcoming, offset: 0, width: prefixWidth, fraction: 1, at: origin)
            draw(attributed: sung, offset: 0, width: prefixWidth, fraction: 1, at: origin)
        }
        for segment in segments {
            if segment.glyphs.isEmpty {
                let duration = max(0.01, segment.end - segment.start)
                let fraction = min(1, max(0, (position - segment.start) / duration))
                draw(
                    attributed: upcoming,
                    offset: segment.offset,
                    width: segment.width,
                    fraction: 1,
                    at: origin
                )
                guard fraction > 0 else { continue }
                draw(
                    attributed: sung,
                    offset: segment.offset,
                    width: segment.width,
                    fraction: fraction,
                    at: origin
                )
                continue
            }

            for glyph in segment.glyphs {
                guard origin.x + glyph.offset + glyph.width >= 0, origin.x + glyph.offset <= bounds.width else { continue }
                let duration = max(0.01, glyph.end - glyph.start)
                let fraction = min(1, max(0, (position - glyph.start) / duration))
                draw(
                    attributed: upcoming,
                    offset: glyph.offset,
                    width: glyph.width,
                    fraction: 1,
                    at: origin
                )
                guard fraction > 0 else { continue }
                draw(
                    attributed: sung,
                    offset: glyph.offset,
                    width: glyph.width,
                    fraction: fraction,
                    at: origin
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(
        attributed: NSAttributedString,
        offset: CGFloat,
        width: CGFloat,
        fraction: Double,
        at origin: NSPoint
    ) {
        guard width > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            rect: NSRect(
                x: origin.x + offset,
                y: origin.y,
                width: width * fraction,
                height: bounds.height
            )
        ).addClip()
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
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

    private func measuredWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func measuredHeight(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).height
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
        let next = renderedOriginX + (target - renderedOriginX) * blend
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
        let metrics = NSAttributedString(
            string: displayText,
            attributes: [.font: font]
        )
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

    private func activateTimer() {
        guard displayTimer == nil, isPlaying || previousLine != nil else { return }
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
