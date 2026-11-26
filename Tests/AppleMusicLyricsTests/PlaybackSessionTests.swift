import XCTest
@testable import AppleMusicLyrics

@MainActor
final class PlaybackSessionTests: XCTestCase {
    private final class Backend: PlaybackBackend {
        var onUpdate: ((PlaybackMonitor.Update) -> Void)?
        var events: [String] = []
        var controlFinished: ((Bool) -> Void)?
        func start() { events.append("start") }
        func stop() { events.append("stop") }
        func sampleNow() { events.append("sample") }
        func performControl(_ args: [String], completion: @escaping (Bool) -> Void) {
            events.append(args.joined(separator: " "))
            controlFinished = completion
        }
    }

    func testSelectionRoutesControlsAndIgnoresOldResultsEvenAfterSwitchingBack() throws {
        let apple = Backend()
        let netease = Backend()
        let session = PlaybackSession(appleMusic: apple, netease: netease)
        var received = 0
        session.onUpdate = { _ in received += 1 }
        session.select(.appleMusic)
        let oldSample = try XCTUnwrap(apple.onUpdate)
        var oldSeek: Bool?
        session.performControl(["seek", "18"]) { oldSeek = $0 }
        session.select(.netease)
        session.select(.netease)
        session.sampleNow()
        session.performControl(["pause"]) { XCTAssertTrue($0) }
        netease.controlFinished?(true)
        netease.onUpdate?(.stopped)
        session.select(.appleMusic)
        oldSample(.musicNotRunning)
        apple.controlFinished?(true)
        XCTAssertEqual(oldSeek, false)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(apple.events, ["start", "seek 18", "stop", "start"])
        XCTAssertEqual(netease.events, ["start", "sample", "pause", "stop"])
    }

    func testTrackIdentitySeparatesPlayersAndKeepsNetEaseIDsDistinct() {
        func track(_ source: PlaybackSource, id: String? = nil) -> TrackInfo {
            TrackInfo(title: "Demo", artist: "A", album: "B", duration: 60, position: 0,
                      state: .playing, source: source, sourceTrackID: id)
        }
        XCTAssertEqual(track(.appleMusic).identityKey, "a|demo|b|60")
        XCTAssertNotEqual(track(.netease).identityKey, track(.appleMusic).identityKey)
        XCTAssertNotEqual(track(.netease, id: "1").identityKey, track(.netease, id: "2").identityKey)
    }
}
