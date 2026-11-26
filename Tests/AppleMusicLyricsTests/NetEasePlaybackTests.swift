import AppKit
import XCTest
@testable import AppleMusicLyrics

final class NetEasePlaybackTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 700)

    private func text(_ name: String, x: Int, y: Int, url: String? = nil) -> NetEaseBarField {
        NetEaseBarField(role: url == nil ? "AXStaticText" : "AXLink", text: name,
                        url: url.flatMap(URL.init(string:)), rect: CGRect(x: x, y: y, width: 60, height: 12))
    }

    func testRealPlayerClockAndTrackLinks() throws {
        let fields = [text("Title", x: 70, y: 637, url: "https://music.163.com/#/song?id=123"),
                      text("Artist", x: 70, y: 657, url: "https://music.163.com/artist?id=456"),
                      text("00:09", x: 500, y: 670), text("03:45", x: 610, y: 670)]
        let info = try XCTUnwrap(NetEaseBarTrack.read(fields, in: window))
        XCTAssertEqual(info.title, "Title")
        XCTAssertEqual(info.artist, "Artist")
        XCTAssertEqual(info.id, "123")
        XCTAssertEqual(info.position, 9)
        XCTAssertEqual(info.duration, 225)
    }

    func testCombinedClockAndMissingOrInconsistentTimes() throws {
        let name = text("现场版 - 演唱者", x: 40, y: 653)
        let info = try XCTUnwrap(NetEaseBarTrack.read([name, text("01:00:10 / 01:05:00", x: 490, y: 669)], in: window))
        XCTAssertEqual(info.title, "现场版")
        XCTAssertEqual(info.artist, "演唱者")
        XCTAssertEqual(info.position, 3610)
        XCTAssertNil(NetEaseBarTrack.read([name, text("15:30 / 01:30", x: 650, y: 680)], in: window))
        XCTAssertNil(NetEaseBarTrack.read([name], in: window))
    }

    func testHeadingWithLinkedArtistAndSliderValueDescription() throws {
        var heading = text("网易云音乐 - 歌名　—　歌手", x: 45, y: 645)
        heading.role = "AXHeading"
        let artist = text("歌手", x: 45, y: 660, url: "https://music.163.com/artist?id=42")
        let slider = NetEaseBarField(role: "AXSlider", text: "播放进度", valueDescription: "00:01 / 03:20",
                                     rect: CGRect(x: 300, y: 655, width: 400, height: 12))
        let info = try XCTUnwrap(NetEaseBarTrack.read([heading, artist, slider], in: window))
        XCTAssertEqual(info.title, "歌名")
        XCTAssertEqual(info.artist, "歌手")
        XCTAssertNil(info.id)
        XCTAssertEqual(info.position, 1)
        XCTAssertEqual(info.duration, 200)
    }

    func testPercentSliderWithDurationAndVolumeDisambiguation() throws {
        let title = text("A song", x: 40, y: 645)
        let duration = text("03:20", x: 810, y: 665)
        var slider = NetEaseBarField(role: "AXSlider", text: "播放进度", sliderValue: 25,
                                     sliderMin: 0, sliderMax: 100,
                                     rect: CGRect(x: 300, y: 662, width: 400, height: 14))
        let info = try XCTUnwrap(NetEaseBarTrack.read([title, slider, duration], in: window))
        XCTAssertEqual(info.position, 50)
        slider.text = "音量"
        XCTAssertNil(NetEaseBarTrack.read([title, slider, duration], in: window))
    }

    func testDurationFromSavedSongCanAnchorAnUnlabelledTimelineClock() throws {
        let slider = NetEaseBarField(role: "AXSlider", text: "进度", sliderValue: 0.35, sliderMin: 0, sliderMax: 1,
                                     rect: CGRect(x: 200, y: 665, width: 500, height: 14))
        let (position, duration) = try XCTUnwrap(NetEaseBarTrack.time(in: [slider], frame: window, knownDuration: 200))
        XCTAssertEqual(position, 70, accuracy: 0.01)
        XCTAssertEqual(duration, 200)
        XCTAssertNil(NetEaseBarTrack.time(in: [slider], frame: window))
    }

    func testChromiumGroupedClockAndDuplicateChildText() throws {
        let title = text("Song", x: 25, y: 640)
        var elapsed = text("01:05", x: 510, y: 670)
        elapsed.role = "AXGroup"
        let child = text("01:05", x: 511, y: 670)
        let total = text("03:00", x: 640, y: 670)
        let info = try XCTUnwrap(NetEaseBarTrack.read([title, elapsed, child, total], in: window))
        XCTAssertEqual(info.position, 65)
        var combined = elapsed
        combined.text = "01:05／03:00"
        XCTAssertEqual(NetEaseBarTrack.read([title, combined], in: window)?.duration, 180)
    }

    func testSteppedSeekOnlyAdvertisesReachableSongPositions() {
        XCTAssertTrue(NetEaseSeekSteps.canReachWholeTrack(range: 100, step: 1, duration: 180))
        XCTAssertFalse(NetEaseSeekSteps.canReachWholeTrack(range: 100, step: 5, duration: 180))
        XCTAssertFalse(NetEaseSeekSteps.canReachWholeTrack(range: 100, step: 0.01, duration: 180))
        XCTAssertFalse(NetEaseSeekSteps.canReachWholeTrack(range: 100, step: 0, duration: 180))
        XCTAssertFalse(NetEaseSeekSteps.canReachWholeTrack(range: 100, step: .nan, duration: 180))
    }

    func testSeekDoesNotImplyPlayingAndNewTrackResetsMotion() {
        var clock = NetEaseClockObservation()
        var track = NetEaseBarTrack(title: "Song", artist: "", id: nil, position: 0, duration: 60)
        XCTAssertEqual(clock.observe(track, at: 0), .unknown)
        track.position = 1
        XCTAssertEqual(clock.observe(track, at: 1), .playing)
        XCTAssertEqual(clock.observe(track, at: 4), .paused)
        track.position = 25
        XCTAssertEqual(clock.observe(track, at: 4.1), .unknown)
        XCTAssertEqual(clock.observe(track, at: 7), .paused)
        track.title = "Another song"
        XCTAssertEqual(clock.observe(track, at: 8), .unknown)
    }
}
