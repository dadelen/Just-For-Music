import AppKit
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class PlaybackControlsTests: XCTestCase {
    func testClickSegmentsRoutePlaybackActionsAndIgnoreUnavailableControls() {
        let controls = PlaybackControls(buttonWidth: 26)
        controls.frame = NSRect(x: 0, y: 0, width: controls.width, height: 24)
        controls.layoutSubtreeIfNeeded()
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: 2, state: .playing)
        controls.update(track)
        var commands: [String] = []
        controls.onPrevious = { commands.append("previous") }
        controls.onToggle = { commands.append("toggle") }
        controls.onNext = { commands.append("next") }
        for x: CGFloat in [13, 39, 65] {
            XCTAssertTrue(controls.activate(at: NSPoint(x: x, y: 12)))
        }
        XCTAssertEqual(commands, ["previous", "toggle", "next"])
        XCTAssertEqual(controls.accessibilityActions.map(\.name), ["上一首", "暂停", "下一首"])
        XCTAssertFalse(controls.activate(at: NSPoint(x: -1, y: 12)))
        controls.update(nil)
        XCTAssertTrue(controls.activate(at: NSPoint(x: 39, y: 12)))
        controls.isHidden = true
        XCTAssertFalse(controls.activate(at: NSPoint(x: 39, y: 12)))
        XCTAssertEqual(commands.count, 3)
    }
}
