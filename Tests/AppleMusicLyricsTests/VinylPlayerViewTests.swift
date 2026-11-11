import AppKit
import QuartzCore
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class VinylPlayerViewTests: XCTestCase {
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
            XCTAssertEqual(cover.bounds.width / record.bounds.width, 0.78, accuracy: 0.001)
            view.update(playing: true, visible: false)
            let root = try XCTUnwrap(view.layer)
            let arm = try XCTUnwrap(root.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineCap == .round })
            let tip = arm.convert(try XCTUnwrap(arm.path).currentPoint, to: root)
            let contactRadius = hypot(tip.x - record.position.x, tip.y - record.position.y)
            XCTAssertGreaterThan(contactRadius, cover.bounds.width / 2)
            XCTAssertLessThan(contactRadius, record.bounds.width / 2)
            let rotation = try XCTUnwrap(record.animation(forKey: "rotation") as? CABasicAnimation)
            XCTAssertEqual(rotation.duration, 6, accuracy: 0.001)
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

    func testTrackChangeWhilePlayingParksTheNeedleBeforeReturning() throws {
        let view = VinylPlayerView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        let arm = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.lineCap == .round })
        view.update(playing: true, visible: true, trackIdentity: "first")
        arm.removeAnimation(forKey: "needle")
        view.update(playing: true, visible: true, trackIdentity: "second")

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNil(arm.animation(forKey: "needle"))
        } else {
            let animation = try XCTUnwrap(arm.animation(forKey: "needle") as? CAKeyframeAnimation)
            let angles = try XCTUnwrap(animation.values as? [Double])
            XCTAssertEqual(angles.count, 4)
            XCTAssertGreaterThan(angles[1], angles[0])
            XCTAssertEqual(angles[1], angles[2])
            XCTAssertEqual(angles[3], angles[0], accuracy: 0.001)
        }

        arm.removeAnimation(forKey: "needle")
        view.update(playing: true, visible: true, trackIdentity: "second")
        XCTAssertNil(arm.animation(forKey: "needle"))

        view.update(playing: false, visible: true, trackIdentity: "second")
        arm.removeAnimation(forKey: "needle")
        view.update(playing: false, visible: true, trackIdentity: "third")
        XCTAssertNil(arm.animation(forKey: "needle"))
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
        XCTAssertEqual(arm.value(forKeyPath: "transform.rotation.z") as? Double, parkedAngle)
        view.update(playing: false, visible: true, trackIdentity: "song")
        view.followPlayback()
        XCTAssertEqual(arm.value(forKeyPath: "transform.rotation.z") as? Double, parkedAngle)
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
}
