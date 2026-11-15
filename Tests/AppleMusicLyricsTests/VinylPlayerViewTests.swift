import AppKit
import QuartzCore
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class VinylPlayerViewTests: XCTestCase {
    func testMetalArtworkReusesExactGeometryAndSeparatesScale() throws {
        let first = VinylMetalRenderer.render(diameter: 160, armLength: 110, scale: 2)
        let repeated = VinylMetalRenderer.render(diameter: 160, armLength: 110, scale: 2)
        XCTAssertTrue(try XCTUnwrap(first.arm) === (try XCTUnwrap(repeated.arm)))
        XCTAssertTrue(try XCTUnwrap(first.pivot) === (try XCTUnwrap(repeated.pivot)))
        let larger = VinylMetalRenderer.render(diameter: 160, armLength: 110, scale: 3)
        XCTAssertGreaterThan(try XCTUnwrap(larger.arm).width, try XCTUnwrap(first.arm).width)
        let longer = VinylMetalRenderer.render(diameter: 160, armLength: 120, scale: 2)
        XCTAssertNotEqual(longer.armBounds, first.armBounds)
    }

    func testBothSizesKeepRecordCircularAndArtworkInsideRecord() throws {
        for size in [NSSize(width: 240, height: 190), NSSize(width: 320, height: 310), NSSize(width: 800, height: 750)] {
            let view = VinylPlayerView(frame: NSRect(origin: .zero, size: size))
            view.layoutSubtreeIfNeeded()
            let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.animation(forKey: "rotation") != nil })
            XCTAssertGreaterThan(record.bounds.width, 0)
            XCTAssertEqual(record.bounds.width, record.bounds.height)
            let cover = try XCTUnwrap(record.sublayers?[2])
            XCTAssertEqual(cover.bounds.width, cover.bounds.height)
            XCTAssertTrue(record.bounds.contains(cover.frame))
            XCTAssertEqual(cover.cornerRadius, cover.bounds.width / 2)
            XCTAssertEqual(cover.bounds.width / record.bounds.width, 0.51, accuracy: 0.001)
            view.update(playing: true, visible: false)
            let root = try XCTUnwrap(view.layer)
            let arm = try XCTUnwrap(root.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineCap == .round })
            let tip = arm.convert(try XCTUnwrap(arm.path).currentPoint, to: root)
            let contactRadius = hypot(tip.x - record.position.x, tip.y - record.position.y)
            XCTAssertGreaterThan(contactRadius, cover.bounds.width / 2)
            XCTAssertLessThan(contactRadius, record.bounds.width / 2)
            let rotation = try XCTUnwrap(record.animation(forKey: "rotation") as? CABasicAnimation)
            XCTAssertEqual(rotation.duration, 6, accuracy: 0.001)
            view.update(playing: false, visible: false)
            let parkedTip = arm.convert(try XCTUnwrap(arm.path).currentPoint, to: root)
            XCTAssertTrue(view.bounds.insetBy(dx: -6, dy: -6).contains(parkedTip))
        }
    }

    func testPauseAndHiddenWindowPreserveAnimationTime() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.animation(forKey: "rotation") != nil })
        view.update(playing: true, visible: true)
        // Reduce Motion deliberately suppresses decorative rotation.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        XCTAssertEqual(record.speed, 1)
        view.update(playing: false, visible: true)
        let pausedTime = record.timeOffset
        XCTAssertEqual(record.speed, 0)
        XCTAssertGreaterThan(pausedTime, 0)
        view.update(playing: false, visible: true)
        XCTAssertEqual(record.timeOffset, pausedTime)
        view.update(playing: true, visible: true)
        XCTAssertEqual(record.speed, 1)
        XCTAssertEqual(record.timeOffset, 0)
        XCTAssertEqual(record.convertTime(CACurrentMediaTime(), from: nil), pausedTime, accuracy: 0.05)
        view.update(playing: true, visible: false)
        XCTAssertEqual(record.speed, 0)
    }

    func testTrackTempoChangesPreserveRotationPhase() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.animation(forKey: "rotation") != nil })
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let rotation = try XCTUnwrap(record.animation(forKey: "rotation"))

        view.update(playing: true, visible: true, trackIdentity: "fast", bpm: 120)
        XCTAssertEqual(rotation.duration / Double(record.speed), 6, accuracy: 0.001)
        let changeTime = CACurrentMediaTime()
        let phaseBeforeChange = record.convertTime(changeTime, from: nil)
        view.update(playing: true, visible: true, trackIdentity: "slow", bpm: 90)
        XCTAssertEqual(rotation.duration / Double(record.speed), 8, accuracy: 0.001)
        XCTAssertEqual(record.convertTime(changeTime, from: nil), phaseBeforeChange, accuracy: 0.02)

        view.update(playing: false, visible: true, trackIdentity: "slow", bpm: 90)
        let pausedPhase = record.timeOffset
        view.update(playing: false, visible: true, trackIdentity: "fast", bpm: 120)
        XCTAssertEqual(record.speed, 0)
        XCTAssertEqual(record.timeOffset, pausedPhase)
        view.update(playing: true, visible: true, trackIdentity: "fast", bpm: 120)
        XCTAssertEqual(record.convertTime(CACurrentMediaTime(), from: nil), pausedPhase, accuracy: 0.02)

        view.update(playing: true, visible: true, trackIdentity: "slow", bpm: 90)
        view.update(playing: true, visible: true, trackIdentity: "missing")
        XCTAssertEqual(rotation.duration / Double(record.speed), 6, accuracy: 0.001)
        view.update(playing: true, visible: true, trackIdentity: "slow", bpm: 90)
        view.update(playing: true, visible: true, trackIdentity: "invalid", bpm: 0)
        XCTAssertEqual(rotation.duration / Double(record.speed), 6, accuracy: 0.001)
    }

    func testTrackChangesReturnToOuterGrooveAndResumeReturnsToSavedProgress() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        view.update(playing: true, visible: false, trackIdentity: "first", position: 180, duration: 200)
        let arm = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.tonearm" })
        let innerAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        view.update(playing: false, visible: false, trackIdentity: "first", position: 180, duration: 200)
        let parked = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        XCTAssertGreaterThan(parked, innerAngle)
        view.update(playing: true, visible: false, trackIdentity: "first", position: 180, duration: 200)
        XCTAssertEqual(try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double), innerAngle, accuracy: 0.001)
        view.update(playing: true, visible: false, trackIdentity: "second", position: 0, duration: 200)
        let outerAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        XCTAssertGreaterThan(outerAngle, innerAngle)
        view.update(playing: true, visible: false, trackIdentity: "second", position: 100, duration: 200)
        let middle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        XCTAssertLessThan(middle, outerAngle)
        XCTAssertGreaterThan(middle, innerAngle)
        view.update(playing: true, visible: false, trackIdentity: "second", position: 0, duration: 200)
        XCTAssertEqual(try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double), outerAngle, accuracy: 0.001)
    }

    func testNeedleHoldsCueWhileMusicStillReportsTheOldState() async throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        let arm = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineCap == .round })
        view.update(playing: true, visible: false, trackIdentity: "song")
        let playingAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        await view.cueNeedle(ontoRecord: false)
        let parkedAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        XCTAssertGreaterThan(parkedAngle, playingAngle)

        view.update(playing: true, visible: true, trackIdentity: "song")
        XCTAssertEqual(try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double), parkedAngle, accuracy: 0.000001)
        view.update(playing: false, visible: true, trackIdentity: "song")
        view.followPlayback()
        XCTAssertEqual(try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double), parkedAngle, accuracy: 0.000001)
        XCTAssertNil(arm.animation(forKey: "needle"))
    }

    func testTonearmActsAsPlaybackButtonWithoutInterceptingRecordCenter() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        view.layoutSubtreeIfNeeded()
        let root = try XCTUnwrap(view.layer)
        let record = try XCTUnwrap(root.sublayers?.first { $0.animation(forKey: "rotation") != nil })
        let arm = try XCTUnwrap(root.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineCap == .round })
        let tip = arm.convert(try XCTUnwrap(arm.path).currentPoint, to: root)

        XCTAssertTrue(view.hitTest(tip) === view)
        view.allowsPlaybackControl = true
        let button = try XCTUnwrap(view.hitTest(tip) as? NSButton)
        XCTAssertTrue(view.hitTest(arm.position) === button)
        XCTAssertTrue(view.hitTest(record.position) === view)

        var toggles = 0
        view.onTogglePlayPause = { toggles += 1 }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1))
        }
        button.mouseDown(with: try mouse(.leftMouseDown, at: tip))
        button.mouseUp(with: try mouse(.leftMouseUp, at: record.position))
        XCTAssertEqual(toggles, 0)
        button.mouseDown(with: try mouse(.leftMouseDown, at: tip))
        button.mouseUp(with: try mouse(.leftMouseUp, at: tip))
        XCTAssertEqual(toggles, 1)
        view.update(playing: true, visible: false)
        XCTAssertEqual(button.accessibilityLabel(), "唱针，暂停")
    }
    func testStylusMovesMonotonicallyInsideGroovesAtAllSupportedSizes() {
        for diameter in [80.0, 151, 240, 660] {
            let geometry = VinylTonearmGeometry(diameter: diameter, center: CGPoint(x: 400, y: 400))
            var previousRadius = Double.infinity
            for step in 0...100 {
                let point = geometry.contact(at: Double(step) / 100)
                let radius = hypot(point.x - geometry.center.x, point.y - geometry.center.y)
                XCTAssertLessThanOrEqual(radius, previousRadius + 0.000001)
                XCTAssertGreaterThanOrEqual(radius, geometry.innerRadius - 0.000001)
                XCTAssertLessThanOrEqual(radius, geometry.outerRadius + 0.000001)
                XCTAssertEqual(hypot(point.x - geometry.pivot.x, point.y - geometry.pivot.y), geometry.armLength, accuracy: 0.000001)
                previousRadius = radius
            }
        }
    }

    func testClockUsesElapsedTimeAndHandlesPauseSeekResetAndInvalidDuration() {
        var clock = VinylPlaybackClock()
        clock.update(position: 20, duration: 200, playing: true, reset: true, at: 100)
        XCTAssertEqual(clock.position(at: 105), 25)
        clock.update(position: 25, duration: 200, playing: false, reset: false, at: 105)
        XCTAssertEqual(clock.position(at: 200), 25)
        clock.update(position: 25, duration: 200, playing: true, reset: false, at: 200)
        XCTAssertEqual(clock.position(at: 205), 30)
        clock.update(position: 180, duration: 200, playing: true, reset: false, at: 205)
        XCTAssertEqual(clock.progress(for: clock.position(at: 210)), 0.925)
        clock.update(position: 10, duration: 200, playing: false, reset: false, at: 210)
        XCTAssertEqual(clock.position(at: 300), 10)
        clock.update(position: nil, duration: 200, playing: false, reset: true, at: 300)
        XCTAssertEqual(clock.position(at: 301), 0)
        for duration in [0.0, -1, Double.nan, .infinity] {
            clock.update(position: .nan, duration: duration, playing: true, reset: true, at: 400)
            XCTAssertEqual(clock.progress(for: clock.position(at: 500)), 0)
        }
    }

    func testSteadyPlaybackReusesMaterialAndSchedulesOnlyTransformAnimation() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        view.update(playing: true, visible: true, trackIdentity: "song", position: 10, duration: 200)
        let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.record" })
        let surface = try XCTUnwrap(record.sublayers?.first)
        let bitmap = try XCTUnwrap(surface.contents as AnyObject?)
        let light = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.environmentLight" })
        let arm = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.tonearm" })
        for second in 11...30 {
            view.update(playing: true, visible: true, trackIdentity: "song", position: Double(second), duration: 200)
            XCTAssertTrue(surface.contents as AnyObject? === bitmap)
        }
        XCTAssertNil(light.mask)
        XCTAssertTrue(light.animationKeys()?.isEmpty ?? true)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let sweep = try XCTUnwrap(arm.animation(forKey: "grooveSweep") as? CAKeyframeAnimation)
            XCTAssertEqual(sweep.keyPath, "transform.rotation.z")
            XCTAssertGreaterThanOrEqual(sweep.duration, 169)
        }
        view.update(playing: false, visible: true, trackIdentity: "song", position: 30, duration: 200)
        XCTAssertNil(arm.animation(forKey: "grooveSweep"))
        view.update(playing: true, visible: false, trackIdentity: "song", position: 50, duration: 200)
        XCTAssertNil(arm.animation(forKey: "grooveSweep"))
        view.update(playing: true, visible: true, trackIdentity: "song", position: 50, duration: 200)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertNotNil(arm.animation(forKey: "grooveSweep")) }
    }

    func testPauseLiftsArmAndStartLowersItBackToCurrentGroove() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        view.update(playing: true, visible: false, trackIdentity: "song", position: 120, duration: 200)
        let arm = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.tonearm" })
        let playingAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        view.update(playing: false, visible: true, trackIdentity: "song", position: 120, duration: 200)
        let parkedAngle = try XCTUnwrap(arm.value(forKeyPath: "transform.rotation.z") as? Double)
        XCTAssertGreaterThan(parkedAngle, playingAngle)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let lift = try XCTUnwrap(arm.animation(forKey: "needle") as? CABasicAnimation)
            XCTAssertEqual(try XCTUnwrap(lift.fromValue as? Double), playingAngle, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(lift.toValue as? Double), parkedAngle, accuracy: 0.001)
        }
        view.update(playing: true, visible: true, trackIdentity: "song", position: 120, duration: 200)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let lower = try XCTUnwrap(arm.animation(forKey: "grooveSweep") as? CAKeyframeAnimation)
            let angles = try XCTUnwrap(lower.values as? [Double])
            XCTAssertEqual(angles[0], parkedAngle, accuracy: 0.001)
            XCTAssertEqual(angles[1], playingAngle, accuracy: 0.001)
        }
    }

    func testLiveResizeReusesBitmapsUntilTheFinalSizeIsCommitted() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        view.layoutSubtreeIfNeeded()
        let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.record" })
        let surface = try XCTUnwrap(record.sublayers?.first)
        let arm = try XCTUnwrap(view.layer?.sublayers?.first { $0.name == "vinyl.tonearm" })
        let armMaterial = try XCTUnwrap(arm.sublayers?.first)
        let originalDisc = try XCTUnwrap(surface.contents as AnyObject?)
        let originalArm = try XCTUnwrap(armMaterial.contents as AnyObject?)

        view.viewWillStartLiveResize()
        for size in [NSSize(width: 260, height: 220), NSSize(width: 280, height: 240), NSSize(width: 300, height: 260)] {
            view.frame.size = size
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(surface.contents as AnyObject? === originalDisc)
            XCTAssertTrue(armMaterial.contents as AnyObject? === originalArm)
        }

        view.viewDidEndLiveResize()
        view.layoutSubtreeIfNeeded()
        let resizedDisc = try XCTUnwrap(surface.contents as AnyObject?)
        let resizedArm = try XCTUnwrap(armMaterial.contents as AnyObject?)
        XCTAssertFalse(resizedDisc === originalDisc)
        XCTAssertFalse(resizedArm === originalArm)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(surface.contents as AnyObject? === resizedDisc)
        XCTAssertTrue(armMaterial.contents as AnyObject? === resizedArm)
        view.viewDidEndLiveResize()
    }

}
