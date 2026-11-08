import XCTest
import Translation
@testable import AppleMusicLyrics

@MainActor
final class LocalTranslationIntegrationTests: XCTestCase {
    func testInstalledSystemTranslationAndTrackIsolationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_TRANSLATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LOCAL_TRANSLATION_INTEGRATION=1 to test installed system language resources")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("Headless translation requires macOS 26") }
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: AppPreferences.highQualityTranslation ? .highFidelity : .lowLatency)
        } else { availability = LanguageAvailability() }
        let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        guard status == .installed else { throw XCTSkip("English → Chinese system resources are not installed; no download requested") }
        guard AppPreferences.automaticTranslation else { throw XCTSkip("Automatic translation is disabled") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(directory: directory)
        let service = LocalTranslationService(cache: cache)
        let done = expectation(description: "New song translated")
        let first = LyricsDocument(lines: [LyricLine(time: 1, text: "The morning sun shines through the window")], plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        let second = first.replacing(lines: [
            LyricLine(time: 2, text: "The quiet garden is full of flowers", confirmedEnd: 5),
            LyricLine(time: 5, text: "I"),
            LyricLine(time: 6, text: "Oh"),
            LyricLine(time: 7, text: "Stay"),
            LyricLine(time: 8, text: "Let go"),
            LyricLine(time: 9, text: "Hello你好"),
            LyricLine(time: 10, text: "We walk together through the quiet city")
        ])
        let currentTrack = TrackInfo(title: "Second", artist: "Test", album: "", duration: 30, position: 0, state: .paused)
        let key = TranslationCache.key(track: currentTrack, document: second, source: "en",
                                       target: AppPreferences.translationTarget, quality: AppPreferences.highQualityTranslation)
        await cache.write([0: "宁静的花园里开满了花"], key: key)
        var statuses: [String] = []
        service.onStatus = { statuses.append($0) }
        service.onResult = { document in
            XCTAssertEqual(document.lines.first?.text, second.lines.first?.text, "Old track must not deliver its result")
            XCTAssertEqual(document.lines.first?.time, 2)
            XCTAssertEqual(document.lines.first?.confirmedEnd, 5)
            XCTAssertEqual(document.lines.first?.translation, "宁静的花园里开满了花")
            XCTAssertEqual(document.lines.filter(\.isMachineTranslation).map(\.time), [2, 5, 6, 7, 8, 10],
                           statuses.joined(separator: "; "))
            done.fulfill()
        }
        service.start(document: first, track: TrackInfo(title: "First", artist: "Test", album: "", duration: 30, position: 0, state: .paused))
        service.start(document: second, track: currentTrack)
        await fulfillment(of: [done], timeout: 45)
        service.cancel()
    }
}
