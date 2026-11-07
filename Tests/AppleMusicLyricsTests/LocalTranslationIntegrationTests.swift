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
        let service = LocalTranslationService(cache: TranslationCache(directory: directory))
        let done = expectation(description: "New song translated")
        let first = LyricsDocument(lines: [LyricLine(time: 1, text: "The morning sun shines through the window")], plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        let second = first.replacing(lines: [LyricLine(time: 2, text: "The quiet garden is full of flowers", confirmedEnd: 5)])
        var statuses: [String] = []
        service.onStatus = { statuses.append($0) }
        service.onResult = { document in
            XCTAssertEqual(document.lines.first?.text, second.lines.first?.text, "Old track must not deliver its result")
            XCTAssertEqual(document.lines.first?.time, 2)
            XCTAssertEqual(document.lines.first?.confirmedEnd, 5)
            XCTAssertFalse(document.lines.first?.translation?.isEmpty ?? true, statuses.joined(separator: "; "))
            done.fulfill()
        }
        service.start(document: first, track: TrackInfo(title: "First", artist: "Test", album: "", duration: 30, position: 0, state: .paused))
        service.start(document: second, track: TrackInfo(title: "Second", artist: "Test", album: "", duration: 30, position: 0, state: .paused))
        await fulfillment(of: [done], timeout: 45)
        service.cancel()
    }
}
