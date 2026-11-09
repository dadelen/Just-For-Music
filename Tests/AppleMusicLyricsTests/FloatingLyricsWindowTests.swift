import AppKit
import CoreImage
import QuartzCore
import ScreenCaptureKit
import Vision
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class FloatingLyricsWindowTests: XCTestCase {
    func testOldVinylModesKeepTheirSizeAfterMigration() {
        let defaults = UserDefaults.standard
        let modeKey = AppPreferences.floatingLyricsModeKey
        let sizeKey = "floatingLyrics.vinylSize"
        let originalMode = defaults.object(forKey: modeKey)
        let originalSize = defaults.object(forKey: sizeKey)
        defer {
            defaults.set(originalMode, forKey: modeKey)
            defaults.set(originalSize, forKey: sizeKey)
        }

        for (legacy, size) in [("small", FloatingLyricsMode.minimumVinylSize),
                               ("large", FloatingLyricsMode.maximumVinylSize)] {
            defaults.set(legacy, forKey: modeKey)
            defaults.removeObject(forKey: sizeKey)
            XCTAssertEqual(AppPreferences.floatingLyricsVinylSize, size)
            AppPreferences.migrate()
            XCTAssertEqual(defaults.string(forKey: modeKey), "vinyl")
            XCTAssertEqual(AppPreferences.floatingLyricsVinylSize, size)
        }
    }

    func testVinylResizeUsesNativeLimitsAndRestoresCustomSizeAcrossModes() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.floatingLyricsMode
        let originalSize = AppPreferences.floatingLyricsVinylSize
        let originalLock = AppPreferences.floatingPositionLocked
        defer {
            AppPreferences.floatingLyricsMode = originalMode
            AppPreferences.floatingLyricsVinylSize = originalSize
            AppPreferences.floatingPositionLocked = originalLock
        }
        AppPreferences.floatingLyricsMode = .vinyl
        AppPreferences.floatingLyricsVinylSize = FloatingLyricsMode.minimumVinylSize
        AppPreferences.floatingPositionLocked = false

        let controller = FloatingLyricsController()
        let fields = Mirror(reflecting: controller).children
        let panel = try XCTUnwrap(fields.first { $0.label == "panel" }?.value as? NSPanel)
        let canvas = try XCTUnwrap(fields.first { $0.label == "canvas" }?.value as? NSView)
        let lockButton = try XCTUnwrap(fields.first { $0.label == "lockButton" }?.value as? NSButton)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.frame.size, FloatingLyricsMode.minimumVinylSize)

        panel.setContentSize(NSSize(width: 1200, height: 600))
        XCTAssertEqual(panel.frame.size, FloatingLyricsMode.maximumVinylSize)
        panel.setContentSize(NSSize(width: 350, height: 180))
        XCTAssertEqual(panel.frame.size, FloatingLyricsMode.minimumVinylSize)

        let custom = NSSize(width: 770, height: 340)
        panel.setContentSize(custom)
        XCTAssertEqual(canvas.frame.maxX, custom.width - 16, accuracy: 0.5)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        XCTAssertEqual(AppPreferences.floatingLyricsVinylSize, custom)

        AppPreferences.floatingLyricsMode = .minimal
        controller.applyPreferences()
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.frame.size, FloatingLyricsMode.minimalSize)
        XCTAssertTrue(panel.isMovable)

        AppPreferences.floatingLyricsMode = .vinyl
        controller.applyPreferences()
        lockButton.performClick(nil)
        XCTAssertTrue(AppPreferences.floatingPositionLocked)
        XCTAssertEqual(panel.frame.size, custom)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(panel.ignoresMouseEvents)

        AppPreferences.floatingPositionLocked = false
        controller.applyPositionLock()
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.frame.size, custom)
        XCTAssertEqual(panel.contentMaxSize, FloatingLyricsMode.maximumVinylSize)
    }

    func testGlassTransparencyFadesOnlyTheFloatingBackdrop() throws {
        _ = NSApplication.shared
        let originalTransparency = AppPreferences.floatingLyricsGlassTransparency
        let shadowKey = AppPreferences.floatingLyricsShadowKey
        let originalShadow = UserDefaults.standard.object(forKey: shadowKey)
        defer {
            AppPreferences.floatingLyricsGlassTransparency = originalTransparency
            UserDefaults.standard.set(originalShadow, forKey: shadowKey)
        }
        UserDefaults.standard.set(true, forKey: shadowKey)
        AppPreferences.floatingLyricsGlassTransparency = 0.6

        let controller = FloatingLyricsController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel)
        let surface = try XCTUnwrap(panel.contentView as? GlassSurface)
        XCTAssertEqual(surface.content.alphaValue, 1)
        XCTAssertEqual(panel.alphaValue, 1)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            XCTAssertEqual(surface.subviews, [surface.content])
            XCTAssertEqual(surface.layer?.backgroundColor?.alpha, 1)
            controller.setGlassTransparency(1)
            XCTAssertTrue(panel.hasShadow)
            return
        }

        let material = try XCTUnwrap(surface.subviews.first { $0 !== surface.content })
        XCTAssertEqual(material.alphaValue, 0.4, accuracy: 0.001)
        XCTAssertFalse(material.isHidden)
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: 0, state: .paused)
        let lines = [LyricLine(time: 0, text: "Current"), LyricLine(time: 5, text: "Next", translation: "下一句")]
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        controller.apply(status: .showing(track: track, lyrics: lyrics, currentLine: "Current"))
        let fields = Mirror(reflecting: controller).children
        let canvas = try XCTUnwrap(fields.first { $0.label == "canvas" }?.value as? NSView)
        let hiddenLayers = try XCTUnwrap(Mirror(reflecting: canvas).children.first { $0.label == "karaokeLayers" }?.value as? [CALayer])
        XCTAssertTrue(hiddenLayers.isEmpty)
        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }
        let lineLayers = try XCTUnwrap(Mirror(reflecting: canvas).children.first { $0.label == "karaokeLayers" }?.value as? [CALayer])
        let currentLine = try XCTUnwrap(lineLayers.first)
        let nextLine = try XCTUnwrap(lineLayers.dropFirst().first)
        let maximumBlur = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.0 : 1.1
        let contextOpacity = nextLine.opacity
        func blurRadius(on layer: CALayer) -> Double {
            let filter = layer.filters?.first as? CIFilter
            return (filter?.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue ?? 0
        }
        XCTAssertEqual(blurRadius(on: nextLine), maximumBlur * 0.4, accuracy: 0.001)
        XCTAssertTrue(panel.hasShadow)
        controller.setGlassTransparency(0.95)
        XCTAssertEqual(material.alphaValue, 0.05, accuracy: 0.001)
        XCTAssertEqual(blurRadius(on: nextLine), maximumBlur * 0.05, accuracy: 0.001)
        XCTAssertFalse(panel.hasShadow)

        controller.setGlassTransparency(1)
        XCTAssertTrue(material.isHidden)
        XCTAssertFalse(surface.content.isHidden)
        XCTAssertFalse(canvas.layerUsesCoreImageFilters)
        XCTAssertEqual(blurRadius(on: nextLine), 0)
        XCTAssertEqual(nextLine.opacity, contextOpacity)
        XCTAssertLessThan(nextLine.opacity, currentLine.opacity)
        XCTAssertEqual(blurRadius(on: currentLine), 0)
        XCTAssertFalse(panel.hasShadow)

        controller.setGlassTransparency(0)
        XCTAssertFalse(material.isHidden)
        XCTAssertTrue(canvas.layerUsesCoreImageFilters)
        XCTAssertEqual(material.alphaValue, 1)
        XCTAssertEqual(blurRadius(on: nextLine), maximumBlur, accuracy: 0.001)
        XCTAssertEqual(blurRadius(on: currentLine), 0)
        XCTAssertTrue(panel.hasShadow)

        UserDefaults.standard.set(false, forKey: shadowKey)
        controller.updateBackdropAppearance()
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(material.alphaValue, 1)
        XCTAssertEqual(blurRadius(on: nextLine), maximumBlur, accuracy: 0.001)
        UserDefaults.standard.set(true, forKey: shadowKey)
        controller.updateBackdropAppearance()
        XCTAssertTrue(panel.hasShadow)
    }

    func testChangingFontSizePreservesTheActiveLineAndItsHighlight() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let fontScaleKey = "lyrics.fontScale"
        let originalFontScale = defaults.object(forKey: fontScaleKey)
        defer { defaults.set(originalFontScale, forKey: fontScaleKey) }
        AppPreferences.fontScale = 0.8

        let controller = FloatingLyricsController()
        let canvas = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "canvas" }?.value as? NSView)
        func lyricLayers() throws -> [CALayer] {
            try XCTUnwrap(Mirror(reflecting: canvas).children.first { $0.label == "karaokeLayers" }?.value as? [CALayer])
        }
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: 7, state: .paused)
        let lines = [LyricLine(time: 0, text: "Earlier"), LyricLine(time: 5, text: "Current", translation: "当前"),
                     LyricLine(time: 10, text: "Next")]
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        controller.apply(status: .showing(track: track, lyrics: lyrics, currentLine: "Current"))
        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }
        let oldRowHeight = try lyricLayers()[1].bounds.height
        canvas.displayIfNeeded()

        let actions = SettingsActions()
        var previewedScales: [Double] = []
        actions.floatingLyricsFontSizeChanged = {
            previewedScales.append(AppPreferences.fontScale)
            controller.reloadLyricsFontSize()
        }
        actions.previewFloatingLyricsFontSize(0.95)
        actions.previewFloatingLyricsFontSize(1.15)
        let previewDeadline = Date().addingTimeInterval(0.5)
        while previewedScales.isEmpty, Date() < previewDeadline {
            RunLoop.main.run(mode: .eventTracking, before: previewDeadline)
        }
        XCTAssertEqual(previewedScales, [1.15])
        XCTAssertGreaterThan(try lyricLayers()[1].bounds.height, oldRowHeight)

        actions.previewFloatingLyricsFontSize(1.3)
        actions.flushFloatingLyricsFontSize()
        XCTAssertEqual(previewedScales, [1.15, 1.3])

        let layers = try lyricLayers()
        let current = layers[1]
        XCTAssertGreaterThan(current.bounds.height, oldRowHeight)
        XCTAssertFalse(current.isHidden)
        XCTAssertEqual(current.opacity, 1)
        XCTAssertLessThan(layers[0].opacity, current.opacity)
        XCTAssertLessThan(layers[2].opacity, current.opacity)
        XCTAssertNil(current.superlayer?.animation(forKey: "lineScroll"))
        let highlightPosition = Mirror(reflecting: current).children.first { $0.label == "lastProgressPosition" }?.value as? TimeInterval
        XCTAssertEqual(highlightPosition, track.position)
        XCTAssertFalse(canvas.needsDisplay)
    }

    func testFloatingLyricsKeepTheWindowAppearanceWhenSwitchingSongs() throws {
        _ = NSApplication.shared
        let originalColor = AppPreferences.floatingLyricsTextColor
        defer { AppPreferences.floatingLyricsTextColor = originalColor }
        AppPreferences.floatingLyricsTextColor = nil

        let controller = FloatingLyricsController()
        let canvas = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "canvas" }?.value as? NSView)
        defer { controller.setVisible(false, animated: false) }
        func showTrack(_ title: String) {
            let track = TrackInfo(title: title, artist: "", album: "", duration: 30, position: 1, state: .paused)
            let line = LyricLine(time: 0, text: title, translation: "译文")
            let lyrics = LyricsDocument(lines: [line], plainText: nil, source: "test", isSynced: true, wordTiming: .none)
            controller.apply(status: .showing(track: track, lyrics: lyrics, currentLine: line.text))
            if !controller.isVisible { controller.setVisible(true, animated: false) }
        }
        func textColors() throws -> [NSColor] {
            let rows = try XCTUnwrap(Mirror(reflecting: canvas).children.first { $0.label == "karaokeLayers" }?.value as? [CALayer])
            let row = try XCTUnwrap(rows.first)
            return try ["upcomingLayer", "supplementaryLayer"].map { label in
                let value = try XCTUnwrap(Mirror(reflecting: row).children.first { $0.label == label }?.value)
                let layer = try XCTUnwrap(value as? CALayer)
                let storage = try XCTUnwrap(Mirror(reflecting: layer).children.first { $0.label == "storage" }?.value as? NSTextStorage)
                return try XCTUnwrap(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            }
        }

        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for (appearance, ambient, expectsLightText) in [(dark, light, true), (light, dark, false)] {
            canvas.appearance = appearance
            for title in ["First track", "Second track"] {
                ambient.performAsCurrentDrawingAppearance { showTrack(title) }
                let colors = try textColors()
                ambient.performAsCurrentDrawingAppearance {
                    for color in colors {
                        let brightness = color.usingColorSpace(.sRGB)?.redComponent ?? -1
                        if expectsLightText { XCTAssertGreaterThan(brightness, 0.65) }
                        else { XCTAssertLessThan(brightness, 0.4) }
                    }
                }
            }
        }
    }

    func testKaraokeKeepsGradientOnlyOnThePartialGlyphAndRestoresItAfterSeeking() throws {
        _ = NSApplication.shared
        let controller = FloatingLyricsController()
        let canvas = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "canvas" }?.value as? NSView)
        let line = LyricLine(time: 1, text: "AB", words: [
            .init(text: "A", start: 1, end: 2),
            .init(text: "B", start: 2, end: 3)
        ])
        let next = LyricLine(time: 6, text: "CD", words: [
            .init(text: "C", start: 6, end: 7),
            .init(text: "D", start: 7, end: 8)
        ])
        let lyrics = LyricsDocument(lines: [line, next], plainText: nil, source: "test", isSynced: true, wordTiming: .exact)
        func track(at position: TimeInterval) -> TrackInfo {
            TrackInfo(title: "Test", artist: "", album: "", duration: 10, position: position, state: .paused)
        }
        func show(at position: TimeInterval) {
            // Showing renders the latest sample even when the test window is occluded.
            controller.setVisible(false, animated: false)
            controller.apply(status: .showing(track: track(at: position), lyrics: lyrics, currentLine: line.text))
            controller.setVisible(true, animated: false)
        }
        show(at: 1.5)
        defer { controller.setVisible(false, animated: false) }

        let rows = try XCTUnwrap(Mirror(reflecting: canvas).children.first { $0.label == "karaokeLayers" }?.value as? [CALayer])
        let units = try XCTUnwrap(rows.first?.sublayers)
        let nextRow = try XCTUnwrap(rows.last)
        XCTAssertEqual(nextRow.sublayers?.count, 1)
        XCTAssertNil(nextRow.sublayers?.first?.sublayers)
        let glyphs = try units.map { try XCTUnwrap($0.sublayers?.last) }
        XCTAssertEqual(glyphs.count, 2)
        XCTAssertEqual(glyphs.map(\.isHidden), [false, true])
        XCTAssertEqual(glyphs.map { $0.mask != nil }, [true, false])

        show(at: 2.5)
        XCTAssertEqual(glyphs.map(\.isHidden), [false, false])
        XCTAssertEqual(glyphs.map { $0.mask != nil }, [false, true])

        show(at: 4)
        XCTAssertEqual(glyphs.map(\.isHidden), [false, false])
        XCTAssertTrue(glyphs.allSatisfy { $0.mask == nil })

        show(at: 1.5)
        XCTAssertEqual(glyphs.map(\.isHidden), [false, true])
        XCTAssertEqual(glyphs.map { $0.mask != nil }, [true, false])

        show(at: 6.5)
        let nextGlyphs = try XCTUnwrap(nextRow.sublayers).map { try XCTUnwrap($0.sublayers?.last) }
        XCTAssertEqual(nextGlyphs.map { $0.mask != nil }, [true, false])
        show(at: 1.5)
        XCTAssertEqual(nextRow.sublayers?.count, 1)
        XCTAssertNil(nextRow.sublayers?.first?.sublayers)
    }

    func testLyricsRenderUprightInTheCompositedWindow() async throws {
        guard ProcessInfo.processInfo.environment["FLOATING_LYRICS_WINDOW_INTEGRATION"] == "1",
              #available(macOS 14.4, *) else {
            throw XCTSkip("Run on a Mac desktop with FLOATING_LYRICS_WINDOW_INTEGRATION=1.")
        }
        _ = NSApplication.shared
        let originalMode = AppPreferences.floatingLyricsMode
        defer { AppPreferences.floatingLyricsMode = originalMode }
        AppPreferences.floatingLyricsMode = .vinyl
        let controller = FloatingLyricsController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel)
        panel.appearance = NSAppearance(named: .aqua)
        panel.center()
        let lines = ["FIRST LINE", "SECOND LINE", "THIRD LINE", "FOURTH LINE"].enumerated().map { index, text in
            let start = Double(index) * 5
            return LyricLine(time: start, text: text, words: [.init(text: text, start: start, end: start + 4)],
                             translation: "Translation \(index + 1)")
        }
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true, wordTiming: .exact)
        let track = TrackInfo(title: "Orientation probe", artist: "", album: "", duration: 30, position: 6, state: .paused)
        controller.apply(status: .showing(track: track, lyrics: lyrics, currentLine: lines[1].text))
        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }

        for transparency in [0.6, 1.0] {
            controller.setGlassTransparency(transparency)
            try await Task.sleep(nanoseconds: 300_000_000)
            // Capture our own test window after the WindowServer composes it.
            let shareable = try await SCShareableContent.currentProcess
            let window = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(panel.frame.width * 2)
            configuration.height = Int(panel.frame.height * 2)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration
            )
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            bitmap.setFillColor(NSColor.white.cgColor)
            bitmap.fill(rect)
            bitmap.draw(image, in: rect)
            let request = VNRecognizeTextRequest()
            request.regionOfInterest = CGRect(x: 0.39, y: 0, width: 0.61, height: 1)
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.makeImage())).perform([request])
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for expected in ["second line", "translation 2", "third line", "translation 3"] {
                XCTAssertTrue(recognized.contains(expected), "Transparency \(transparency), recognized \(recognized)")
            }
        }
    }

    func testWindowFocusRedrawsTrafficLightsAndOutlinesTransparentWindow() throws {
        _ = NSApplication.shared
        let controller = FloatingLyricsController()
        let fields = Mirror(reflecting: controller).children
        let panel = try XCTUnwrap(fields.first { $0.label == "panel" }?.value as? NSPanel)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let buttons = try ["closeButton", "lockButton", "modeButton"].map { name in
            try XCTUnwrap(fields.first { $0.label == name }?.value as? NSButton)
        }
        let surfaceLayer = try XCTUnwrap(panel.contentView?.layer)
        controller.setGlassTransparency(1)
        XCTAssertEqual(surfaceLayer.borderWidth, 0)

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            buttons.forEach { $0.layer?.displayIfNeeded() }
            XCTAssertTrue(buttons.allSatisfy { $0.layer?.needsDisplay() == false })
            NotificationCenter.default.post(name: name, object: panel)
            XCTAssertTrue(buttons.allSatisfy { $0.layer?.needsDisplay() == true })
            let showsOutline = name == NSWindow.didBecomeKeyNotification
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            XCTAssertEqual(surfaceLayer.borderWidth, showsOutline ? 1 : 0)
        }

        controller.setGlassTransparency(0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        XCTAssertEqual(surfaceLayer.borderWidth, 0)
    }

    func testLockedFloatingWindowKeepsAllThreeButtonsAtTheirScreenPositions() throws {
        _ = NSApplication.shared
        let originalLock = AppPreferences.floatingPositionLocked
        defer { AppPreferences.floatingPositionLocked = originalLock }
        AppPreferences.floatingPositionLocked = false

        let controller = FloatingLyricsController()
        let fields = Mirror(reflecting: controller).children
        let panel = try XCTUnwrap(fields.first { $0.label == "panel" }?.value as? NSPanel)
        let buttons = try ["closeButton", "lockButton", "modeButton"].map { name in
            try XCTUnwrap(fields.first { $0.label == name }?.value as? NSButton)
        }
        func screenFrames() -> [NSRect] {
            buttons.map { $0.window!.convertToScreen($0.convert($0.bounds, to: nil)) }
        }

        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }
        let originalFrames = screenFrames()
        buttons[1].performClick(nil)
        let child = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(child.ignoresMouseEvents)
        XCTAssertTrue(buttons.allSatisfy { $0.window === child })
        XCTAssertEqual(screenFrames(), originalFrames)

        buttons[0].performClick(nil)
        XCTAssertFalse(controller.isVisible)
        CATransaction.flush()
        let deadline = Date().addingTimeInterval(1)
        while (panel.isVisible || child.isVisible) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(child.isVisible)
        controller.setVisible(true, animated: false)
        XCTAssertTrue(buttons.allSatisfy { $0.window === child })

        buttons[1].performClick(nil)
        XCTAssertFalse(AppPreferences.floatingPositionLocked)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(child.isVisible)
        XCTAssertTrue(buttons.allSatisfy { $0.window === panel })
        XCTAssertEqual(screenFrames(), originalFrames)
    }

    func testLockedVinylKeepsOnlyThePlaybackButtonInteractive() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.floatingLyricsMode
        let originalLock = AppPreferences.floatingPositionLocked
        defer {
            AppPreferences.floatingLyricsMode = originalMode
            AppPreferences.floatingPositionLocked = originalLock
        }
        AppPreferences.floatingLyricsMode = .vinyl
        AppPreferences.floatingPositionLocked = true
        let controller = FloatingLyricsController()
        let fields = Mirror(reflecting: controller).children
        let panel = try XCTUnwrap(fields.first { $0.label == "panel" }?.value as? NSPanel)
        let vinyl = try XCTUnwrap(fields.first { $0.label == "vinyl" }?.value as? VinylPlayerView)
        let button = try XCTUnwrap(Mirror(reflecting: vinyl).children.first { $0.label == "tonearmButton" }?.value as? NSButton)
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 60, position: 2, state: .playing)
        controller.apply(status: .noLyrics(track))
        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }

        let child = try XCTUnwrap(button.window)
        XCTAssertTrue(child.parent === panel)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(child.ignoresMouseEvents)
        XCTAssertEqual(child.frame, panel.convertToScreen(vinyl.convert(vinyl.needleButtonFrame, to: nil)).integral)
        XCTAssertLessThan(child.frame.width, vinyl.frame.width)
        let pivot = try XCTUnwrap(Mirror(reflecting: vinyl).children.first { $0.label == "pivot" }?.value as? CAShapeLayer)
        let contentLayer = try XCTUnwrap(child.contentView?.layer)
        XCTAssertTrue(pivot.superlayer === contentLayer)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(child.frame.width), height: Int(child.frame.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        contentLayer.render(in: bitmap)
        let pixels = try XCTUnwrap(bitmap.data?.assumingMemoryBound(to: UInt8.self))
        let centerAlpha = Int(child.frame.height / 2) * bitmap.bytesPerRow + Int(child.frame.width / 2) * 4 + 3
        XCTAssertEqual(pixels[centerAlpha], 255)
        var presses = 0
        controller.onVinylTogglePlayPause = { presses += 1 }
        button.performClick(nil)
        XCTAssertEqual(presses, 1)

        AppPreferences.floatingLyricsMode = .minimal
        controller.applyPreferences()
        XCTAssertFalse(child.isVisible)
        XCTAssertTrue(button.window === panel)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testAlwaysOnTopSettingChangesBothTheFloatingWindowAndItsLockedControls() throws {
        _ = NSApplication.shared
        let originalLock = AppPreferences.floatingPositionLocked
        let originalAlwaysOnTop = AppPreferences.floatingLyricsShowOverFullScreen
        defer {
            AppPreferences.floatingPositionLocked = originalLock
            AppPreferences.floatingLyricsShowOverFullScreen = originalAlwaysOnTop
        }
        AppPreferences.floatingPositionLocked = true
        AppPreferences.floatingLyricsShowOverFullScreen = true

        let controller = FloatingLyricsController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel)
        controller.setVisible(true, animated: false)
        defer { controller.setVisible(false, animated: false) }
        let controls = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(controls.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))

        AppPreferences.floatingLyricsShowOverFullScreen = false
        controller.applyPreferences()
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertEqual(controls.level, .normal)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertEqual(controls.collectionBehavior, panel.collectionBehavior)

        AppPreferences.floatingLyricsShowOverFullScreen = true
        controller.applyPreferences()
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(controls.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
    }

    func testMoveBurstSavesOnlyFinalPosition() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Window positioning requires a screen") }
        let originalFrames = AppPreferences.floatingLyricsFramesByDisplay
        let originalDisplay = AppPreferences.floatingLyricsLastDisplay
        defer {
            AppPreferences.floatingLyricsFramesByDisplay = originalFrames
            AppPreferences.floatingLyricsLastDisplay = originalDisplay
        }

        let controller = FloatingLyricsController()
        let panel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel)
        let notification = Notification(name: NSWindow.didMoveNotification, object: panel)
        let origin = panel.frame.origin
        for dx in 1...120 {
            panel.setFrameOrigin(NSPoint(x: origin.x + CGFloat(dx) / 10, y: origin.y))
            controller.windowDidMove(notification)
        }
        XCTAssertEqual(AppPreferences.floatingLyricsFramesByDisplay, originalFrames)

        // Exercise the same flush path used on quit and window hide.
        controller.savePendingPosition()
        let display = try XCTUnwrap(AppPreferences.floatingLyricsLastDisplay)
        XCTAssertEqual(AppPreferences.floatingLyricsFramesByDisplay[display], NSStringFromRect(panel.frame))
    }
}
