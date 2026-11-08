import XCTest
@testable import AppleMusicLyrics

final class LyricsLanguageDetectorTests: XCTestCase {
    private func document(_ lines: [String]) -> LyricsDocument {
        LyricsDocument(lines: lines.enumerated().map { LyricLine(time: Double($0.offset), text: $0.element) },
                       plainText: nil, source: "test", isSynced: true, wordTiming: .none)
    }

    func testChineseAndMixedLinesAreSkippedWhileEnglishLinesRemain() {
        let lyrics = document([
            "今天我们一起走过这条街", "今天我們一起走過這條街", "今晚陪你一起 walking under the stars",
            "We walk together through the quiet city", "The morning light falls softly on the road",
            "I remember all the lights along the avenue", "The stars are fading in the early morning sky"
        ])
        let groups = LyricsLanguageDetector.groups(for: lyrics)
        XCTAssertEqual(Set(groups.flatMap { $0.lines.keys }), [3, 4, 5, 6])
        XCTAssertEqual(Set(groups.map(\.language)), ["en"])
    }

    func testEnglishLinesInMainlyChineseLyricsAreSkipped() {
        let lyrics = document([
            "夜深的时候我独自走在回家的路上",
            "想起从前我们并肩看过的那些风景",
            "I keep walking down this empty road and wonder where the morning light will take me",
            "後來才明白有些故事只能留在心裡",
            "We could sing together until the sun rises above the mountains and the city wakes again",
            "明天的太阳还会照亮熟悉的窗台",
            "我把想说的话写进这首歌里"
        ])
        XCTAssertTrue(LyricsLanguageDetector.groups(for: lyrics).isEmpty)
    }

    func testJapaneseWithKanjiIsNotClassifiedAsChineseByScriptAlone() {
        let lyrics = document(["君と歩いたこの道をいつまでも覚えている", "夜の街を静かに歩いていた"])
        XCTAssertEqual(LyricsLanguageDetector.groups(for: lyrics).first?.language, "ja")
        XCTAssertEqual(LyricsLanguageDetector.groups(for: lyrics).first?.lines.count, 2)
    }

    func testShortHanLyricsAreUncertainUnlessTheSourceDeclaresJapanese() {
        let lyrics = document(["未来", "夜空"])
        XCTAssertEqual(LyricsLanguageDetector.songLanguage(for: lyrics), .uncertain)
        XCTAssertTrue(LyricsLanguageDetector.groups(for: lyrics).isEmpty)

        let tagged = LyricsDocument(lines: lyrics.lines, plainText: nil, source: "test", isSynced: true,
                                    wordTiming: .none, sourceLanguage: "ja-JP")
        XCTAssertEqual(LyricsLanguageDetector.songLanguage(for: tagged), .foreign)
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

    func testShortForeignLinesUseSongContextWithoutIncludingChineseOrMixedLines() {
        let lyrics = document([
            "We walk together through the quiet city", "I", "Oh", "Stay", "Let go",
            "我们一起走", "Hello你好", "…", "밤",
            "The morning light falls softly on the road"
        ])
        let groups = Dictionary(uniqueKeysWithValues: LyricsLanguageDetector.groups(for: lyrics).map {
            ($0.language, Set($0.lines.keys))
        })
        XCTAssertEqual(groups, ["en": [0, 1, 2, 3, 4, 9], "ko": [8]])
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

    func testAlbumChangeSeparatesTrackIdentity() {
        let first = TrackInfo(title: "Same song", artist: "Same artist", album: "Studio", duration: 120, position: 0, state: .paused)
        let second = TrackInfo(title: "Same song", artist: "Same artist", album: "Live", duration: 120, position: 0, state: .paused)
        XCTAssertNotEqual(first.identityKey, second.identityKey)
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
