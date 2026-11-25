import XCTest
@testable import AppleMusicLyrics

final class LyricsGapTests: XCTestCase {
    func testHarmonyExtendsTheSungIntervalBeforeAndAfterTheLead() {
        let harmony = LyricHarmony(time: 1, words: [.init(text: "(Echo)", start: 1, end: 7)])
        let lines = [
            LyricLine(time: 2, text: "Lead", confirmedEnd: 4, harmonies: [harmony]),
            LyricLine(time: 8.5, text: "Next", confirmedEnd: 9)
        ]
        let lyrics = LyricsDocument(lines: lines, plainText: nil, source: "test",
                                    isSynced: true, wordTiming: .exact)
        let gaps = lyrics.addingGaps(duration: 10).lines.filter(\.isGap)
        XCTAssertEqual(gaps.map(\.time), [7])
        XCTAssertEqual(gaps.map(\.confirmedEnd), [8.5])
    }

    private func document(_ xml: String) throws -> LyricsDocument {
        let parsed = try AppleTTMLParser.parse("<tt><body><div>\(xml)</div></body></tt>")
        return LyricsDocument(lines: parsed.lines, plainText: nil, source: "test", isSynced: true, wordTiming: parsed.wordTiming)
    }

    func testIntroInterludeAndOutroUseExplicitBoundaries() throws {
        let source = try document("<p begin='3s' end='5s'>First</p><p begin='9s' end='12s'>Second</p>")
        let result = source.addingGaps(duration: 16)
        XCTAssertEqual(result.lines.filter(\.isGap).map(\.time), [0, 5, 12])
        XCTAssertEqual(result.lines.filter(\.isGap).map(\.confirmedEnd), [3, 9, 16])
        XCTAssertEqual(result.line(at: 9)?.text, "Second")
        XCTAssertEqual(result.lines.filter { !$0.isGap }, source.lines)
        XCTAssertEqual(result.lines[0].text, "•\u{2009}•\u{2009}•")
        XCTAssertEqual(result.lines[0].words.map(\.start), [0, 1, 2])
        XCTAssertEqual(result.lines[0].words.map(\.end), [1, 2, 3])
    }

    func testSyntheticEndsAreNotUsedForGapProgress() throws {
        let source = try document("<p begin='0s'>Unknown end</p><p begin='9s'>Still unknown</p>")
        XCTAssertTrue(source.lines.allSatisfy { $0.confirmedEnd == nil })
        XCTAssertEqual(source.addingGaps(duration: 30).lines, source.lines)
    }

    func testOverlappingLyricsAndShortGapsStayOnLyrics() throws {
        let source = try document("<p begin='0s' end='8s'>First</p><p begin='3s' end='5s'>Second</p><p begin='9s' end='12s'>Third</p>")
        XCTAssertFalse(source.addingGaps(duration: 12).lines.contains(where: \.isGap))
    }
}
