import AppKit
import QuartzCore
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class VinylPlayerViewTests: XCTestCase {
    func testBothSizesKeepRecordCircularAndArtworkInsideRecord() throws {
        for size in [NSSize(width: 240, height: 190), NSSize(width: 320, height: 310)] {
            let view = VinylPlayerView(frame: NSRect(origin: .zero, size: size))
            view.layoutSubtreeIfNeeded()
            let record = try XCTUnwrap(view.layer?.sublayers?.first { $0.animation(forKey: "rotation") != nil })
            XCTAssertGreaterThan(record.bounds.width, 0)
            XCTAssertEqual(record.bounds.width, record.bounds.height)
            let cover = try XCTUnwrap(record.sublayers?[2])
            XCTAssertEqual(cover.bounds.width, cover.bounds.height)
            XCTAssertTrue(record.bounds.contains(cover.frame))
            XCTAssertEqual(cover.cornerRadius, cover.bounds.width / 2)
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
}
