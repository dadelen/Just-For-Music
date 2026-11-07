import XCTest
@testable import AppleMusicLyrics

final class LyricsLanguageDetectorTests: XCTestCase {
    private func document(_ lines: [String]) -> LyricsDocument {
        LyricsDocument(lines: lines.enumerated().map { LyricLine(time: Double($0.offset), text: $0.element) },
                       plainText: nil, source: "test", isSynced: true, wordTiming: .none)
    }

    func testChineseAndMixedLinesAreSkippedWhileEnglishLinesRemain() {
        let lyrics = document(["今天我们一起走过这条街", "今天我們一起走過這條街", "今晚陪你一起 walking under the stars", "We walk together through the quiet city", "The morning light falls softly on the road"])
        let groups = LyricsLanguageDetector.groups(for: lyrics)
        XCTAssertEqual(Set(groups.flatMap { $0.lines.keys }), [3, 4])
        XCTAssertEqual(Set(groups.map(\.language)), ["en"])
    }

    func testJapaneseWithKanjiIsNotClassifiedAsChineseByScriptAlone() {
        let lyrics = document(["君と歩いたこの道をいつまでも覚えている", "夜の街を静かに歩いていた"])
        XCTAssertEqual(LyricsLanguageDetector.groups(for: lyrics).first?.language, "ja")
        XCTAssertEqual(LyricsLanguageDetector.groups(for: lyrics).first?.lines.count, 2)
    }

    func testExistingChineseTranslationAndPunctuationAreSkipped() {
        let line = LyricLine(time: 0, text: "The sunlight warms the empty room", translation: "阳光温暖空房间", translationLanguage: "zh-Hans")
        let doc = document(["…", "", "1234"]).replacing(lines: [line, LyricLine(time: 2, text: "…")])
        XCTAssertTrue(LyricsLanguageDetector.groups(for: doc).isEmpty)
    }

    func testMixedChineseAndOtherScriptsAreSkipped() {
        let lyrics = document(["今晚我们一起 안녕하세요", "今天我們一起 bonjour", "我们一起привет", "Hello你好"])
        XCTAssertTrue(LyricsLanguageDetector.groups(for: lyrics).isEmpty)
    }

    func testTranslationCacheRoundTripAndCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(directory: directory)
        await cache.write([0: "测试译文", 3: "第二句"], key: "test")
        let result = await cache.read("test")
        XCTAssertEqual(result, [0: "测试译文", 3: "第二句"])
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("test.json"))
        let corrupted = await cache.read("test")
        XCTAssertNil(corrupted)
    }

    func testCacheKeyChangesWithLyricsAndTranslationStrategy() {
        let track = TrackInfo(title: "Synthetic", artist: "Test", album: "Album", duration: 30, position: 0, state: .paused)
        let first = document(["The sunlight warms the empty room"])
        let second = document(["The moonlight fills the empty room"])
        let key = TranslationCache.key(track: track, document: first, source: "en", target: "zh-Hans", quality: true)
        XCTAssertNotEqual(key, TranslationCache.key(track: track, document: second, source: "en", target: "zh-Hans", quality: true))
        XCTAssertNotEqual(key, TranslationCache.key(track: track, document: first, source: "en", target: "zh-Hans", quality: false))
        XCTAssertEqual(key, TranslationCache.key(track: track, document: first, source: "en", target: "zh-Hans", quality: true))
    }
}
