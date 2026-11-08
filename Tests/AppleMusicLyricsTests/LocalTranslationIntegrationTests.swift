import XCTest
import Translation
@testable import AppleMusicLyrics

@MainActor
final class LocalTranslationIntegrationTests: XCTestCase {
    func testAutomaticTranslationIsOffWithoutAStoredPreference() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Translation requires macOS 15") }
        let key = AppPreferences.automaticTranslationKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let service = LocalTranslationService()
        var statuses: [String] = []
        service.onStatus = { statuses.append($0) }
        let track = TrackInfo(title: "Test", artist: "", album: "", duration: 30, position: 0, state: .paused)
        let document = LyricsDocument(lines: [LyricLine(time: 1, text: "We walk together through the quiet city")],
                                      plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        service.start(document: document, track: track)
        XCTAssertEqual(statuses, ["自动翻译已关闭"])
    }

    func testMissingSystemLanguageResourcesKeepOriginalLyricsWithoutRequestingDownload() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Translation requires macOS 15") }
        let key = AppPreferences.automaticTranslationKey
        let previousAutomatic = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previousAutomatic, forKey: key) }
        AppPreferences.automaticTranslation = true

        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let target = Locale.Language(identifier: AppPreferences.translationTarget)
        let samples = [
            ("de", "Heute gehen wir gemeinsam durch die stillen Straßen der Stadt."),
            ("fr", "Dans les rues de la ville, les lumières brillent jusqu'au matin."),
            ("es", "Caminamos por las calles tranquilas de la ciudad durante la noche."),
            ("it", "Le luci della città si spengono quando il sole tramonta lentamente."),
            ("ja", "朝になったら遠くの海までひとりで歩いてみたい。")
        ]
        var missingDocument: LyricsDocument?
        for (language, text) in samples {
            let document = LyricsDocument(lines: [LyricLine(time: 1, text: text)],
                                          plainText: nil, source: "test", isSynced: true, wordTiming: .none)
            guard LyricsLanguageDetector.groups(for: document).map(\.language) == [language],
                  await availability.status(from: Locale.Language(identifier: language), to: target) == .supported else { continue }
            missingDocument = document
            break
        }
        guard let document = missingDocument else { throw XCTSkip("Requires a supported but uninstalled language") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A detached host cannot service a download request. The translation must finish without it.
        let service = LocalTranslationService(cache: TranslationCache(directory: directory))
        defer { service.cancel() }
        let finished = expectation(description: "Missing language pack reported")
        var result: LyricsDocument?
        service.onResult = { result = $0 }
        service.onStatus = { status in
            if status.hasPrefix("缺少"), status.contains("语言包") { finished.fulfill() }
        }
        let track = TrackInfo(title: "Missing resources", artist: "", album: "", duration: 30, position: 0, state: .paused)
        service.start(document: document, track: track)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, document)
    }

    func testLowLatencyReusesHighQualityCacheAndKeepsCompletedRequest() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Translation requires macOS 15") }
        let defaults = UserDefaults.standard
        let preference = AppPreferences.automaticTranslationKey
        let previousAutomatic = defaults.object(forKey: preference)
        defer { defaults.set(previousAutomatic, forKey: preference) }
        AppPreferences.automaticTranslation = true

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(directory: directory)
        let service = LocalTranslationService(cache: cache)
        let track = TrackInfo(title: "Cache test", artist: "", album: "", duration: 30, position: 0, state: .paused)
        let doc = LyricsDocument(lines: [LyricLine(time: 1, text: "The morning sun shines through the window")],
                                 plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        let key = TranslationCache.key(track: track, document: doc, source: "en",
                                       target: AppPreferences.translationTarget, quality: true)
        await cache.write([0: "缓存中的译文"], key: key)

        let ready = expectation(description: "Reused cached translation")
        var statuses: [String] = []
        service.onStatus = { statuses.append($0) }
        service.onResult = {
            XCTAssertEqual($0.lines.first?.translation, "缓存中的译文")
            ready.fulfill()
        }
        service.start(document: doc, track: track)
        service.start(document: doc, track: track)
        await fulfillment(of: [ready], timeout: 5)
        service.suspend()
        service.start(document: doc, track: track)
        XCTAssertEqual(statuses, ["正在识别歌词语言…", "本地译文已就绪"])
        service.cancel()
    }

    func testInstalledSystemTranslationAndTrackIsolationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_TRANSLATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LOCAL_TRANSLATION_INTEGRATION=1 to test installed system language resources")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("Headless translation requires macOS 26") }
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { availability = LanguageAvailability() }
        let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        guard status == .installed else { throw XCTSkip("English → Chinese system resources are not installed; no download requested") }
        let preference = AppPreferences.automaticTranslationKey
        let previousAutomatic = UserDefaults.standard.object(forKey: preference)
        defer { UserDefaults.standard.set(previousAutomatic, forKey: preference) }
        AppPreferences.automaticTranslation = true
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
                                       target: AppPreferences.translationTarget, quality: false)
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
