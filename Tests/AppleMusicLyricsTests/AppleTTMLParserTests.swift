import Foundation
import XCTest
@testable import AppleMusicLyrics

final class AppleTTMLParserTests: XCTestCase {
    func testParsesWordTimingAndPreservesSeparators() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            itunes:timing="Word">
          <body>
            <div>
              <p begin="1.000" end="3.500">
                <span begin="1.000" end="2.000">Hello</span> <span begin="2.000" end="3.500">world</span>
              </p>
              <p begin="1:02.500" end="1:04.000"><span begin="1:02.500" end="1:04.000">再见</span></p>
            </div>
          </body>
        </tt>
        """

        let result = try AppleTTMLParser.parse(ttml)

        XCTAssertEqual(result.wordTiming, .exact)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "Hello world")
        XCTAssertEqual(result.lines[0].words.map(\.text), ["Hello", " world"])
        XCTAssertEqual(result.lines[0].words[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].words[1].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].time, 62.5, accuracy: 0.001)
    }

    func testParsesLineTimedTTMLWithoutInventingWordTiming() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="2500ms" end="4s">One line</p></div></body>
        </tt>
        """

        let result = try AppleTTMLParser.parse(ttml)

        XCTAssertEqual(result.wordTiming, .none)
        XCTAssertEqual(result.lines.first?.text, "One line")
        XCTAssertEqual(result.lines.first?.time ?? 0, 2.5, accuracy: 0.001)
    }

    func testSeparatesSingerTracksAndExplicitHarmonyUsingTheMetadataNamespace() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:m="http://www.w3.org/ns/ttml#metadata"
            xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions">
          <head><metadata>
            <m:agent xml:id="v2" type="person"/><m:agent xml:id="v1" type="person"/>
            <m:agent xml:id="v3" type="group"/>
            <itunes:iTunesMetadata>
              <itunes:translations><itunes:translation type="subtitle" xml:lang="zh">
                <itunes:text for="L1">译文</itunes:text>
              </itunes:translation></itunes:translations>
            </itunes:iTunesMetadata>
          </metadata></head>
          <body><div>
            <p begin="1s" end="5s" m:agent="v1" itunes:key="L1"><m:ignore/>
              <span m:role="lyrics x-bg"><span begin="1s" end="2s">（同</span><span begin="2s" end="3s">唱）</span></span>
              <span begin="2s" end="5s">Hello</span>
            </p>
            <p begin="4s" end="8s" m:agent="v2"><span begin="4s" end="8s">World</span>
              <span m:role="x-bg" begin="5s" end="7s">(Echo)</span>
            </p>
            <p begin="8s" end="9s" m:agent="v3">Together</p>
          </div></body>
        </tt>
        """
        let parsed = try AppleTTMLParser.parse(ttml)
        XCTAssertEqual(parsed.wordTiming, .exact)
        XCTAssertEqual(parsed.lines.map(\.text), ["Hello", "World", "Together"])
        XCTAssertEqual(parsed.lines.map(\.vocalRole), [.lead, .partner, .lead])
        XCTAssertEqual(parsed.lines[0].translation, "译文")
        XCTAssertEqual(parsed.lines[0].words, [LyricWord(text: "Hello", start: 2, end: 5)])
        XCTAssertEqual(parsed.lines[0].harmonies.first?.words, [
            LyricWord(text: "（同", start: 1, end: 2), LyricWord(text: "唱）", start: 2, end: 3)
        ])
        XCTAssertEqual(parsed.lines[1].harmonies.first?.words, [LyricWord(text: "(Echo)", start: 5, end: 7)])

        let document = LyricsDocument(lines: parsed.lines, plainText: nil, source: "test",
                                      isSynced: true, wordTiming: parsed.wordTiming)
        let presentation = document.applyingMachineTranslations([1: "世界"]).floatingLines
        XCTAssertEqual(presentation.map(\.text), ["同唱", "Hello", "World", "Echo", "Together"])
        XCTAssertEqual(presentation.map(\.time), [1, 1, 4, 5, 8])
        XCTAssertEqual(presentation.map(\.vocalRole), [.leadHarmony, .lead, .partner, .partnerHarmony, .lead])
        XCTAssertEqual(presentation.map(\.isRightAligned), [true, false, true, true, false])
        XCTAssertEqual(presentation[2].translation, "世界")
        XCTAssertEqual(presentation[0].words, [
            LyricWord(text: "同", start: 1, end: 2), LyricWord(text: "唱", start: 2, end: 3)
        ])
    }

    func testBracketFallbackKeepsInteriorParenthesesAndPreservesSpanTimes() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="1s" end="4s">Sing (very) softly</p>
          <p begin="4s" end="8s"><span begin="4s" end="5s">主唱</span>
            <span begin="5s" end="8s">（和声 (echo)）</span>
          </p>
          <p begin="8s" end="9s">(Oh)</p>
          <p begin="9s" end="10s">A mismatched (aside）</p>
          <p begin="10s" end="12s">再见（回声）</p>
          <p begin="12s" end="13s">\u{200E}（一起）！\u{200F}</p>
        </div></body></tt>
        """
        let lines = try AppleTTMLParser.parse(ttml).lines
        XCTAssertEqual(lines.map(\.text), [
            "Sing (very) softly", "主唱", "(Oh)", "A mismatched (aside）", "再见", "\u{200E}（一起）！\u{200F}"
        ])
        XCTAssertEqual(lines.map(\.vocalRole), [.lead, .lead, .leadHarmony, .lead, .lead, .leadHarmony])
        XCTAssertTrue(lines[0].harmonies.isEmpty)
        XCTAssertEqual(lines[1].harmonies.first?.words, [
            LyricWord(text: "（和声 (echo)）", start: 5, end: 8)
        ])
        let inferredHarmony = try XCTUnwrap(lines[4].harmonies.first)
        XCTAssertEqual(inferredHarmony.text, "（回声）")
        XCTAssertEqual(inferredHarmony.time, 10 + 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(inferredHarmony.words.last?.end, 12)
        let document = LyricsDocument(lines: lines, plainText: nil, source: "test",
                                      isSynced: true, wordTiming: .exact)
        XCTAssertEqual(document.floatingLines.map(\.text), [
            "Sing (very) softly", "主唱", "和声 (echo)", "Oh", "A mismatched (aside）", "再见", "回声", "\u{200E}一起！\u{200F}"
        ])
        XCTAssertEqual(document.floatingLines.map(\.isRightAligned), [false, false, true, true, false, false, true, true])
    }

    func testFloatingHarmonyHidesRepeatedOuterBracketsAcrossTimedSpans() {
        let words = [
            LyricWord(text: "(", start: 1, end: 1.1),
            LyricWord(text: "Echo", start: 1.1, end: 1.9),
            LyricWord(text: ") （", start: 1.9, end: 2),
            LyricWord(text: "回声）", start: 2, end: 3)
        ]
        let line = LyricLine(time: 1, text: "(Echo) （回声）", words: words, vocalRole: .leadHarmony)
        let document = LyricsDocument(lines: [line], plainText: nil, source: "test",
                                      isSynced: true, wordTiming: .exact)
        let displayed = document.floatingLines.first
        XCTAssertEqual(displayed?.text, "Echo 回声")
        XCTAssertEqual(displayed?.time, 1)
        XCTAssertEqual(displayed?.words.filter { !$0.text.allSatisfy(\.isWhitespace) }, [
            LyricWord(text: "Echo", start: 1.1, end: 1.9), LyricWord(text: "回声", start: 2, end: 3)
        ])
        XCTAssertEqual(document.lines.first?.words, words)
    }
}
