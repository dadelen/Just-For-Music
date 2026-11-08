import AppKit
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class PlaybackControlsTests: XCTestCase {
    func testNeedleSettlesBeforeSendingPauseOrPlay() async {
        for (state, movement, command) in [(PlayerState.playing, "lift", "pause"), (.paused, "lower", "play")] {
            let song = track("Song", state: state)
            var steps: [String] = []
            await NeedlePlayback.run(.toggle, startingAt: song, moveNeedle: { engaged in
                steps.append(engaged ? "lower" : "lift")
                await Task.yield()
                steps.append("settled")
            }, perform: {
                steps.append($0.rawValue)
                return true
            }, currentTrack: { song })
            XCTAssertEqual(steps, [movement, "settled", command])
        }
    }

    func testNeedleTrackChangeRestoresPlaybackOnlyWhenItWasPlaying() async {
        for state in [PlayerState.playing, .paused] {
            let song = track("First", state: state)
            var current = song
            var steps: [String] = []
            await NeedlePlayback.run(.next, startingAt: song, moveNeedle: {
                steps.append($0 ? "lower" : "lift")
            }, perform: { command in
                steps.append(command.rawValue)
                if command == .cueNext { current = self.track("Second", state: .paused) }
                return true
            }, currentTrack: { current })
            let expected = state == .playing ? ["lift", "cue-next", "lower", "play"] : ["lift", "cue-next"]
            XCTAssertEqual(steps, expected)
        }
    }

    func testNeedleDoesNotSendDelayedCommandAfterTrackChangesExternally() async {
        let song = track("First", state: .paused)
        var current = song
        var commands: [MusicPlaybackController.Command] = []
        await NeedlePlayback.run(.toggle, startingAt: song, moveNeedle: { _ in
            current = self.track("Second", state: .paused)
        }, perform: {
            commands.append($0)
            return true
        }, currentTrack: { current })
        XCTAssertTrue(commands.isEmpty)
    }

    func testNeedleConfirmationWaitsPastOldPlaybackSamples() {
        for (before, after) in [(PlayerState.playing, PlayerState.paused), (.paused, .playing)] {
            let song = track("First", state: before)
            let expectation = PlaybackMonitor.CommandExpectation(state: after, trackKey: song.identityKey)

            XCTAssertNil(expectation.resolution(for: .track(song)))
            XCTAssertEqual(expectation.resolution(for: .track(track("First", state: after))), true)
            XCTAssertEqual(expectation.resolution(for: .track(track("Second", state: after))), false)
        }
    }

    private func track(_ title: String, state: PlayerState) -> TrackInfo {
        TrackInfo(title: title, artist: "", album: "", duration: 30, position: 0, state: state)
    }

    func testFloatingPlaybackButtonsAndVinylNeedleUseSeparateActions() throws {
        _ = NSApplication.shared
        let originalMode = AppPreferences.floatingLyricsMode
        defer { AppPreferences.floatingLyricsMode = originalMode }
        AppPreferences.floatingLyricsMode = .minimal
        let floating = FloatingLyricsController()
        let fields = Mirror(reflecting: floating).children
        let controls = try XCTUnwrap(fields.first { $0.label == "controls" }?.value as? PlaybackControls)
        let vinyl = try XCTUnwrap(fields.first { $0.label == "vinyl" }?.value as? VinylPlayerView)
        controls.layoutSubtreeIfNeeded()
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: 2, state: .playing)
        controls.update(track)
        var commands: [String] = []
        floating.onPreviousTrack = { commands.append("previous") }
        floating.onTogglePlayPause = { commands.append("toggle") }
        floating.onNextTrack = { commands.append("next") }
        floating.onVinylTogglePlayPause = { commands.append("needle") }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["上一首", "暂停", "下一首"])
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(commands, ["previous", "toggle", "next"])
        controls.update(nil)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })

        AppPreferences.floatingLyricsMode = .vinyl
        floating.applyPreferences()
        vinyl.onTogglePlayPause?()
        XCTAssertEqual(commands, ["previous", "toggle", "next", "needle"])
    }
}
