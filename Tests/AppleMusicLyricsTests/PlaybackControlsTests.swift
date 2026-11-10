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

    func testQueuedTransportCommandsShareOneHelperAndOneFreshSample() async throws {
        let url = try makeHelper(
            #"""
            IFS= read -r request && [ "$request" = sample ] || exit 1
            printf '%s\n' '{"kind":"track","title":"Before","artist":"","album":"","duration":30,"position":1,"state":"playing"}'
            IFS= read -r request && [ "$request" = "$(printf 'next\ttoggle\tseek 12.0')" ] || exit 2
            printf '%s\n' '{"kind":"track","title":"After","artist":"","album":"","duration":30,"position":12,"state":"playing","controlErrors":[null,"denied",null]}'
            IFS= read -r request
            """#
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let monitor = PlaybackMonitor(helperURL: url)
        defer { monitor.stop() }
        let controller = MusicPlaybackController(monitor: monitor)
        let done = expectation(description: "received the batch's sample")
        var events: [String] = []
        monitor.onUpdate = { update in
            guard case .track(let track) = update else { return }
            events.append("\(track.title):\(Int(track.position))")
            if track.title == "After" { done.fulfill() }
        }

        monitor.sampleNow()
        controller.perform(.next) { events.append("next:\($0)") }
        controller.perform(.toggle) { events.append("toggle:\($0)") }
        controller.seek(to: 12) { events.append("seek:\($0)") }

        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(events, ["Before:1", "next:true", "toggle:false", "seek:true", "After:12"])
    }

    func testHelperExitFailsPendingCommandsAndRestartsForTheNextClick() async throws {
        let url = try makeHelper(
            #"""
            if [ ! -f "$0.failed" ]; then
                : > "$0.failed"
                IFS= read -r request
                exit 1
            fi
            IFS= read -r request && [ "$request" = previous ] || exit 2
            printf '%s\n' '{"kind":"stopped","controlErrors":[null]}'
            IFS= read -r request
            """#
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let monitor = PlaybackMonitor(helperURL: url)
        defer { monitor.stop() }
        let controller = MusicPlaybackController(monitor: monitor)
        let done = expectation(description: "both commands complete")
        done.expectedFulfillmentCount = 2
        done.assertForOverFulfill = true
        for command: MusicPlaybackController.Command in [.next, .toggle] {
            controller.perform(command) { succeeded in
                XCTAssertFalse(succeeded)
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 3)

        let restarted = expectation(description: "new command succeeds on the restarted helper")
        controller.perform(.previous) { succeeded in
            XCTAssertTrue(succeeded)
            restarted.fulfill()
        }
        await fulfillment(of: [restarted], timeout: 3)
    }

    private func makeHelper(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("playback-helper")
        try ("#!/bin/sh\n" + source + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
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
