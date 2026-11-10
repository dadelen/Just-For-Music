import XCTest
@testable import AppleMusicLyrics

final class AppleMusicCacheIntegrationTests: XCTestCase {
    @MainActor
    func testCurrentMusicTrackWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["APPLE_MUSIC_CACHE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set APPLE_MUSIC_CACHE_INTEGRATION=1 to test the current Music.app track")
        }
        let monitor = PlaybackMonitor()
        defer { monitor.stop() }
        let sampled = expectation(description: "read current track from playback helper")
        var current: TrackInfo?
        monitor.onUpdate = { [weak monitor] update in
            monitor?.onUpdate = nil
            if case .track(let track) = update { current = track }
            sampled.fulfill()
        }
        monitor.start()
        await fulfillment(of: [sampled], timeout: 5)

        let track = try XCTUnwrap(current, "Music.app has no readable current track")
        let document = await LyricsService().lyrics(for: track)
        XCTAssertFalse(document.lines.isEmpty, "No matching Apple Music cache response")
        XCTAssertEqual(document.source, "Apple Music")
        XCTAssertEqual(document.wordTiming, .exact)
        XCTAssertTrue(document.lines.contains { !$0.words.isEmpty })
    }
}
