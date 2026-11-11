import AppKit
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class StatusBarPlaybackTests: XCTestCase {
    func testLegacyStatusBarModesMigrateToAutomatic() {
        let key = AppPreferences.statusBarModeKey
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        for legacyMode in ["full", "compact"] {
            defaults.set(legacyMode, forKey: key)
            AppPreferences.migrate()
            XCTAssertEqual(AppPreferences.statusBarMode, .automatic)
            XCTAssertEqual(defaults.string(forKey: key), "automatic")
        }
        AppPreferences.statusBarMode = .icon
        AppPreferences.migrate()
        XCTAssertEqual(AppPreferences.statusBarMode, .icon)
    }

    func testExpandedPlayerGroupsTrackDetailsAndSeekBarBesideRoundedArtwork() throws {
        _ = NSApplication.shared
        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let panel = try XCTUnwrap(fields.first { $0.label == "playerPanel" }?.value as? NSPanel)
        let surface = try XCTUnwrap(panel.contentView as? GlassSurface)
        let player = try XCTUnwrap(fields.first { $0.label == "playerView" }?.value as? NSView)
        let statusItem = try XCTUnwrap(fields.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let button = try XCTUnwrap(statusItem.button)
        let song = String(repeating: "Long title ", count: 15)
        controller.apply(status: .noLyrics(TrackInfo(
            title: song, artist: "Artist", album: "Album", duration: 120, position: 30, state: .playing
        )))
        let landscape = NSImage(size: NSSize(width: 192, height: 96), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        controller.setArtwork(landscape)
        XCTAssertFalse(player.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == song })
        button.performClick(nil)
        defer { panel.orderOut(nil) }
        surface.layoutSubtreeIfNeeded()

        let cover = try XCTUnwrap(player.subviews.compactMap { $0 as? NSImageView }.first)
        let slider = try XCTUnwrap(player.subviews.compactMap { $0 as? NSSlider }.first)
        let labels = player.subviews.compactMap { $0 as? NSTextField }
        let title = try XCTUnwrap(labels.first { $0.stringValue == song })
        let artist = try XCTUnwrap(labels.first { $0.stringValue == "Artist · Album" })
        let elapsed = try XCTUnwrap(labels.first { $0.stringValue == "0:30" })
        let remaining = try XCTUnwrap(labels.first { $0.stringValue == "-1:30" })
        XCTAssertEqual(cover.image?.size, NSSize(width: 96, height: 96))
        XCTAssertEqual(cover.layer?.cornerRadius, 8)
        XCTAssertTrue(cover.layer?.masksToBounds == true)
        XCTAssertTrue(slider.isEnabled)
        XCTAssertEqual(slider.knobThickness, 12)
        XCTAssertEqual(title.alignment, .left)
        XCTAssertEqual(artist.alignment, .left)
        let trackAlignment = slider.alignmentRect(forFrame: slider.frame)
        for label in [title, artist, elapsed] {
            XCTAssertEqual(label.alignmentRect(forFrame: label.frame).minX, trackAlignment.minX, accuracy: 0.5)
        }
        XCTAssertEqual(remaining.alignmentRect(forFrame: remaining.frame).maxX, trackAlignment.maxX, accuracy: 0.5)
        XCTAssertGreaterThan(slider.frame.minX, cover.frame.maxX)
        XCTAssertLessThan(slider.frame.maxY, artist.frame.minY)
        XCTAssertTrue(labels.allSatisfy { player.bounds.contains($0.frame) })
        XCTAssertFalse(player.subviews.contains { $0 is NSButton || $0 is NSStackView })
    }

    func testRepeatedStatusClickKeepsAnExpandedPlayerOpen() throws {
        _ = NSApplication.shared
        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let statusItem = try XCTUnwrap(fields.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let button = try XCTUnwrap(statusItem.button)
        let panel = try XCTUnwrap(fields.first { $0.label == "playerPanel" }?.value as? NSPanel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertTrue(panel.isVisible)

        button.performClick(nil)
        button.performClick(nil)
        XCTAssertTrue(panel.isVisible)
    }

    func testStatusGapShowsTrackAndAdvancesAtTheLyricTimestampWithoutPolling() async throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.statusBarMode
        defer { AppPreferences.statusBarMode = originalMode }
        AppPreferences.statusBarMode = .automatic
        let controller = MenuBarController()
        let item = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let button = try XCTUnwrap(item.button)
        let track = TrackInfo(title: "Song", artist: "Artist", album: "", duration: 30, position: 2.85, state: .playing)
        let lyrics = LyricsDocument(lines: [LyricLine(time: 3, text: "First lyric")], plainText: nil,
                                    source: "test", isSynced: true, wordTiming: .none).addingGaps(duration: track.duration)

        controller.updateKaraokeProgress(track: track, lyrics: lyrics)
        XCTAssertEqual(button.accessibilityLabel(), "打开播放器，Song — Artist")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(button.accessibilityLabel(), "打开播放器，First lyric")
    }

    func testProgressKeepsNewestSeekWhileMusicReportsOldPositions() throws {
        let app = NSApplication.shared
        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let player = try XCTUnwrap(fields.first { $0.label == "playerView" }?.value as? NSView)
        let panel = try XCTUnwrap(fields.first { $0.label == "playerPanel" }?.value as? NSPanel)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let slider = try XCTUnwrap(player.subviews.compactMap { $0 as? NSSlider }.first)
        func sample(_ position: TimeInterval, title: String = "Test") {
            controller.apply(status: .noLyrics(TrackInfo(
                title: title, artist: "", album: "", duration: 120, position: position, state: .playing
            )))
        }

        var seeks: [TimeInterval] = []
        controller.onSeek = { seeks.append($0) }
        sample(10)
        let seek = try XCTUnwrap(slider.action)
        for position: TimeInterval in [35, 80] {
            slider.doubleValue = position
            XCTAssertTrue(app.sendAction(seek, to: slider.target, from: slider))
            sample(11)
            XCTAssertEqual(slider.doubleValue, position)
        }
        sample(35)
        XCTAssertEqual(slider.doubleValue, 80)
        sample(80.25)
        sample(81)
        XCTAssertEqual(slider.doubleValue, 81)

        slider.doubleValue = 100
        XCTAssertTrue(app.sendAction(seek, to: slider.target, from: slider))
        sample(0, title: "Next track")
        XCTAssertEqual(slider.doubleValue, 0)
        XCTAssertEqual(seeks, [35, 80, 100])

        let target = slider.target
        let trackingCell = SimulatedProgressTrackingCell()
        slider.cell = trackingCell
        slider.target = target
        slider.action = seek
        slider.isContinuous = true
        panel.contentView?.layoutSubtreeIfNeeded()
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        sample(10)
        trackingCell.onTrack = {
            slider.doubleValue = 45
            XCTAssertTrue(app.sendAction(seek, to: target, from: slider))
            XCTAssertTrue(player.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "0:45" })
            XCTAssertEqual(seeks, [35, 80, 100])
            sample(11)
            XCTAssertEqual(slider.doubleValue, 45)
        }
        slider.mouseDown(with: mouseDown)
        XCTAssertEqual(seeks, [35, 80, 100, 45])

        trackingCell.onTrack = {
            slider.doubleValue = 60
            sample(2, title: "Next track")
        }
        slider.mouseDown(with: mouseDown)
        XCTAssertEqual(seeks, [35, 80, 100, 45])
        XCTAssertEqual(slider.doubleValue, 2)
        trackingCell.onTrack = nil
    }

    func testStaticLyricsDoNotRequestRepeatedStatusBarRedraws() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.statusBarMode
        defer { AppPreferences.statusBarMode = originalMode }
        AppPreferences.statusBarMode = .automatic

        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let title = try XCTUnwrap(fields.first { $0.label == "karaokeTitleView" }?.value as? NSView)
        let line = LyricLine(time: 0, text: "Untimed line")
        let lyrics = LyricsDocument(lines: [line], plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        func sample(_ position: TimeInterval) -> TrackInfo {
            TrackInfo(title: "Test", artist: "", album: "", duration: 120, position: position, state: .playing)
        }

        controller.apply(status: .showing(track: sample(1), lyrics: lyrics, currentLine: line.text))
        title.needsDisplay = false
        controller.updateKaraokeProgress(track: sample(1.25), lyrics: lyrics)
        XCTAssertFalse(title.needsDisplay)
    }

    func testStatusLyricsUseSystemMenuFontAndFollowAppearanceUntilCustomized() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = [AppPreferences.statusBarModeKey, "menuBarLyrics.activeColor", "menuBarLyrics.inactiveColor"]
        let original = keys.map(defaults.object(forKey:))
        defer { for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) } }
        AppPreferences.statusBarMode = .automatic
        AppPreferences.resetMenuBarLyricsColors()

        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let title = try XCTUnwrap(fields.first { $0.label == "karaokeTitleView" }?.value as? NSView)
        let button = try XCTUnwrap(fields.first { $0.label == "lyricButton" }?.value as? NSButton)
        let statusItem = try XCTUnwrap(fields.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let statusButton = try XCTUnwrap(statusItem.button)
        let systemFont = NSFont.menuBarFont(ofSize: 0)
        XCTAssertEqual(button.font, systemFont)
        XCTAssertEqual(Mirror(reflecting: title).children.first { $0.label == "font" }?.value as? NSFont, systemFont)

        let line = LyricLine(time: 0, text: "Test lyrics", words: [LyricWord(text: "Test lyrics", start: 0, end: 1)])
        let lyrics = LyricsDocument(lines: [line], plainText: nil, source: "test", isSynced: true, wordTiming: .exact)
        func brightness(_ appearance: NSAppearance.Name, position: TimeInterval) throws -> Double {
            statusButton.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: position, state: .paused)
            controller.updateKaraokeProgress(track: track, lyrics: lyrics)
            let width = Int(title.bounds.width * 2)
            let height = Int(title.bounds.height * 2)
            let bitmap = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: 2, y: -2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            title.draw(title.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
            var red = 0
            var alpha = 0
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * bitmap.bytesPerRow + x * 4
                    red += Int(pixels[index])
                    alpha += Int(pixels[index + 3])
                }
            }
            XCTAssertGreaterThan(alpha, 0)
            return Double(red) / Double(max(1, alpha))
        }

        for position: TimeInterval in [0, 2] {
            XCTAssertLessThan(try brightness(.vibrantLight, position: position), 0.45)
            XCTAssertGreaterThan(try brightness(.vibrantDark, position: position), 0.65)
        }
        AppPreferences.menuBarLyricsActiveColor = NSColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1)
        AppPreferences.menuBarLyricsInactiveColor = NSColor(srgbRed: 0.4, green: 0.2, blue: 0.2, alpha: 1)
        controller.reloadAppearance()
        for position: TimeInterval in [0, 2] {
            XCTAssertEqual(try brightness(.aqua, position: position), try brightness(.darkAqua, position: position), accuracy: 0.02)
        }
        AppPreferences.resetMenuBarLyricsColors()
        controller.reloadAppearance()
        XCTAssertLessThan(try brightness(.aqua, position: 2), 0.45)
    }

    func testLyricTransitionErasesTheOldLineOnTheFirstFrame() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.statusBarMode
        defer { AppPreferences.statusBarMode = originalMode }
        AppPreferences.statusBarMode = .automatic
        let controller = MenuBarController()
        let title = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "karaokeTitleView" }?.value as? NSView)
        let lines = [LyricLine(time: 0, text: "WWWWWWWWW"), LyricLine(time: 2, text: "I")]
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true, wordTiming: .none)

        let width = Int(title.bounds.width * 2)
        let height = Int(title.bounds.height * 2)
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: 2, y: -2)
        let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        func hasInk(in columns: Range<Int>) -> Bool {
            (0..<height).contains { row in
                columns.contains { pixels[row * bitmap.bytesPerRow + $0 * 4 + 3] > 0 }
            }
        }
        func drawLine(at position: TimeInterval) {
            let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: position, state: .paused)
            controller.updateKaraokeProgress(track: track, lyrics: lyrics)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            title.draw(title.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }

        let leftQuarter = 0..<(width / 4)
        drawLine(at: 0)
        XCTAssertTrue(hasInk(in: leftQuarter))
        drawLine(at: 2)
        XCTAssertFalse(hasInk(in: leftQuarter))
        XCTAssertTrue(hasInk(in: (width / 4)..<(3 * width / 4)))
    }

    func testNativeStatusItemsRoutePlaybackAndHideInIconMode() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.statusBarMode
        defer { AppPreferences.statusBarMode = originalMode }
        AppPreferences.statusBarMode = .automatic

        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let lyrics = try XCTUnwrap(fields.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let items = try ["previousStatusItem", "toggleStatusItem", "nextStatusItem"].map { name in
            try XCTUnwrap(fields.first { $0.label == name }?.value as? NSStatusItem)
        }
        let buttons = try items.map { try XCTUnwrap($0.button) }
        let lyricsButton = try XCTUnwrap(lyrics.button)
        XCTAssertTrue(items.allSatisfy(\.isVisible))
        XCTAssertEqual(Set(items.map(\.autosaveName)).count, 3)
        XCTAssertTrue(buttons.allSatisfy { $0.action != lyricsButton.action && $0.target === controller })
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })

        var actions: [String] = []
        controller.onPreviousTrack = { actions.append("previous") }
        controller.onTogglePlayPause = { actions.append("toggle") }
        controller.onNextTrack = { actions.append("next") }
        controller.apply(status: .noLyrics(TrackInfo(
            title: "Test", artist: "", album: "", duration: 30, position: 2, state: .playing
        )))

        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["上一首", "暂停", "下一首"])
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(actions, ["previous", "toggle", "next"])

        controller.apply(status: .noLyrics(TrackInfo(
            title: "Test", artist: "", album: "", duration: 30, position: 2, state: .paused
        )))
        XCTAssertEqual(buttons[1].accessibilityLabel(), "播放")

        AppPreferences.statusBarMode = .icon
        controller.reloadAppearance()
        XCTAssertTrue(items.allSatisfy { !$0.isVisible })
        XCTAssertEqual(lyrics.length, NSStatusBar.system.thickness)
        AppPreferences.statusBarMode = .automatic
        controller.reloadAppearance()
        XCTAssertTrue(items.allSatisfy(\.isVisible))
    }

    func testFloatingLyricsHandoffHidesTheStatusItemAndRestoresTheLatestLine() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.statusBarMode
        defer { AppPreferences.statusBarMode = originalMode }
        AppPreferences.statusBarMode = .automatic

        let controller = MenuBarController()
        let fields = Mirror(reflecting: controller).children
        let statusItem = try XCTUnwrap(fields.first { $0.label == "statusItem" }?.value as? NSStatusItem)
        let view = try XCTUnwrap(fields.first { $0.label == "karaokeTitleView" }?.value as? NSView)
        let playbackItems = try ["previousStatusItem", "toggleStatusItem", "nextStatusItem"].map { name in
            try XCTUnwrap(fields.first { $0.label == name }?.value as? NSStatusItem)
        }
        let lines = [LyricLine(time: 0, text: "First"), LyricLine(time: 5, text: "Second")]
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        func track(at position: TimeInterval) -> TrackInfo {
            TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: position, state: .paused)
        }

        controller.apply(status: .showing(track: track(at: 0), lyrics: lyrics, currentLine: "First"))
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertFalse(view.isHidden)

        controller.setFloatingLyricsVisible(true)
        controller.reloadAppearance()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !statusItem.isVisible }, object: nil)
        wait(for: [hidden], timeout: 2)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(playbackItems.allSatisfy(\.isVisible))

        controller.updateKaraokeProgress(track: track(at: 6), lyrics: lyrics)
        XCTAssertTrue(view.isHidden)
        controller.setFloatingLyricsVisible(false, animated: false)
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(statusItem.button?.accessibilityLabel(), "打开播放器，Second")

        AppPreferences.statusBarMode = .icon
        controller.reloadAppearance()
        XCTAssertTrue(playbackItems.allSatisfy { !$0.isVisible })
        controller.setFloatingLyricsVisible(true, animated: false)
        XCTAssertFalse(statusItem.isVisible)
        XCTAssertTrue(playbackItems.allSatisfy(\.isVisible))
        controller.setFloatingLyricsVisible(false, animated: false)
        XCTAssertTrue(statusItem.isVisible)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(playbackItems.allSatisfy { !$0.isVisible })
    }
}

private final class SimulatedProgressTrackingCell: NSSliderCell {
    var onTrack: (() -> Void)?

    override func trackMouse(with event: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        onTrack?()
        return true
    }
}
