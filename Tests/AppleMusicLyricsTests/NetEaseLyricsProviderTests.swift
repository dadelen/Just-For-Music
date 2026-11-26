import Foundation
import XCTest
@testable import AppleMusicLyrics

final class NetEaseLyricsProviderTests: XCTestCase {
    func testYRCUsesSingerSectionMarkersWithoutChangingWordTiming() throws {
        let document = try parse([
            "code": 200,
            "yrc": ["lyric": """
                [0,500](0,250,0)女 (250,250,0):
                [1000,900](1000,900,0)第一段
                [2000,900](2000,900,0)（回声）
                [3000,900](3000,100,0)男(3100,100,0)： (3200,700,0)第二段
                [4500,900](4500,900,0)合：一起唱
                """]
        ])
        XCTAssertEqual(document.wordTiming, .exact)
        XCTAssertEqual(document.lines.map(\.text), ["第一段", "（回声）", "第二段", "一起唱"])
        XCTAssertEqual(document.lines.map(\.vocalRole), [.partner, .partnerHarmony, .lead, .lead])
        XCTAssertEqual(document.floatingLines.map(\.isRightAligned), [true, true, false, false])
        XCTAssertEqual(document.lines[2].words, [LyricWord(text: "第二段", start: 3.2, end: 3.9)])
        XCTAssertEqual(document.lines[3].words, [LyricWord(text: "一起唱", start: 4.5, end: 5.4)])
    }

    func testLRCUsesExactCreditedNamesToAssignDuetVerses() throws {
        let payload: [String: Any] = [
            "code": 200,
            "lrc": ["lyric": "[00:01]甲：\n[00:02]第一句\n[00:03]下一句\n[00:04]乙: 第二段\n[00:06]合：一起唱"]
        ]
        let duet = try parse(payload, artists: ["甲", "乙"])
        XCTAssertEqual(duet.lines.map(\.time), [2, 3, 4, 6])
        XCTAssertEqual(duet.lines.map(\.text), ["第一句", "下一句", "第二段", "一起唱"])
        XCTAssertEqual(duet.lines.map(\.vocalRole), [.lead, .lead, .partner, .lead])

        let unknown = try parse(payload, artists: ["甲", "丙"])
        XCTAssertEqual(unknown.lines.map(\.text), ["甲：", "第一句", "下一句", "乙: 第二段", "合：一起唱"])
        XCTAssertFalse(unknown.lines.contains { $0.vocalRole == .partner })
    }

    func testYRCBuildsIndependentHarmonyRowsWithTheirOwnTimings() throws {
        let document = try parse([
            "code": 200,
            "yrc": ["lyric": """
                [1000,4000](1000,1000,0)主(3000,1000,0)唱(2500,400,0)（(2900,700,0)回声(3600,10,0)）
                [4200,1200](4200,500,0)(Oh (4700,600,0)oh)
                [6000,2000](6000,600,0)Sing (6600,600,0)(once) (7200,800,0)again
                [8500,1000](8500,600,0)编曲：音乐人(9100,400,0)（工作室）
                """],
            "ytlrc": ["lyric": "[00:01.000]主唱译文"],
            "romalrc": ["lyric": "[00:04.200]ō"]
        ])
        XCTAssertEqual(document.wordTiming, .exact)
        XCTAssertEqual(document.lines.map(\.vocalRole), [.lead, .leadHarmony, .lead, .lead])
        XCTAssertEqual(document.lines[0].translation, "主唱译文")
        XCTAssertEqual(document.lines[1].transliteration, "ō")
        XCTAssertEqual(document.lines[2].text, "Sing (once) again")
        XCTAssertEqual(document.lines[3].text, "编曲：音乐人（工作室）")
        let rows = document.floatingLines
        XCTAssertEqual(rows.map(\.text), ["主唱", "回声", "Oh oh", "Sing (once) again", "编曲：音乐人（工作室）"])
        XCTAssertEqual(rows[1].time, 2.5)
        XCTAssertEqual(rows[1].words, [LyricWord(text: "回声", start: 2.9, end: 3.6)])
        XCTAssertTrue(rows[1].vocalRole.isRightAligned)
    }

    func testLRCRecognizesOnlyWholeParenthesizedLinesAndKeepsLeadActiveAtTheSameTime() throws {
        let document = try parse([
            "code": 200,
            "lrc": ["lyric": """
                [00:01]Main
                [00:01]（和声 (echo)）
                [00:03]Sing (once)
                [00:04](mismatched）
                [00:05]\u{200E}(Echo)!\u{200F}
                [00:06]（）！
                """],
            "tlyric": ["lyric": "[00:01]主唱译文"]
        ])
        XCTAssertEqual(document.wordTiming, .none)
        XCTAssertEqual(document.line(at: 1)?.text, "Main")
        XCTAssertEqual(document.line(at: 1)?.translation, "主唱译文")
        XCTAssertEqual(document.floatingLines.map(\.text), [
            "和声 (echo)", "Main", "Sing (once)", "(mismatched）", "\u{200E}Echo!\u{200F}", "（）！"
        ])
        XCTAssertEqual(document.floatingLines.map(\.vocalRole), [.leadHarmony, .lead, .lead, .lead, .leadHarmony, .lead])
        XCTAssertEqual(document.floatingLines.map(\.isRightAligned), [true, false, false, false, true, false])
        XCTAssertTrue(document.floatingLines[0].words.isEmpty)
    }

    func testYRCHarmonySharingAMarkerKeepsTheSuppliedInterval() throws {
        let document = try parse([
            "code": 200,
            "yrc": ["lyric": "[1000,2400](1000,500,0)主(1500,700,0)唱🙂（回(2200,1000,0)声）！\u{200E}"]
        ])
        XCTAssertEqual(document.wordTiming, .exact)
        let rows = document.floatingLines
        XCTAssertEqual(rows.map(\.text), ["主唱🙂", "回声！\u{200E}"])
        XCTAssertEqual(rows.map(\.time), [1, 1.5])
        XCTAssertEqual(rows.map(\.isRightAligned), [false, true])
        XCTAssertEqual(rows[0].words, [
            LyricWord(text: "主", start: 1, end: 1.5),
            LyricWord(text: "唱🙂", start: 1.5, end: 2.2)
        ])
        XCTAssertEqual(rows[1].words, [
            LyricWord(text: "回", start: 1.5, end: 2.2),
            LyricWord(text: "声！\u{200E}", start: 2.2, end: 3.2)
        ])
    }

    func testYRCUsesAbsoluteWordTimingsAndAlignsTranslationsWithoutShifting() throws {
        let data: [String: Any] = [
            "code": 200,
            "yrc": ["lyric": "{\"t\":0}\n[10000,2000](10000,500,0)One (11000,600,0)two\n[15000,900](15000,900,0)Three"],
            "lrc": ["lyric": "[00:09.5]Unused"],
            "ytlrc": ["lyric": "[00:15.055]三"],
            "romalrc": ["lyric": "[00:10.01]ā"],
        ]
        let output = try parse(data)
        XCTAssertEqual(output.wordTiming, .exact)
        XCTAssertEqual(output.lines.map(\.text), ["One two", "Three"])
        XCTAssertEqual(output.lines[0].words, [
            LyricWord(text: "One ", start: 10, end: 10.5),
            LyricWord(text: "two", start: 11, end: 11.6)
        ])
        XCTAssertEqual(output.lines[0].confirmedEnd, 12)
        XCTAssertNil(output.lines[0].translation)
        XCTAssertEqual(output.lines[1].translation, "三")
        XCTAssertEqual(output.lines[0].transliteration, "ā")
    }

    func testDecodesCommonHTMLEntitiesInYRCAndLRCWithoutDoubleDecoding() throws {
        let yrcDoc = try parse([
            "code": 200,
            "yrc": ["lyric": "[1000,2000](1000,800,0)don&apos;t (1800,600,0)&quot;cry&quot; (2400,600,0)A&amp;B&amp;apos;s"],
            "ytlrc": ["lyric": "[00:01.000]别&lt;哭&gt;&#39;了"]
        ])
        XCTAssertEqual(yrcDoc.lines.first?.text, "don't \"cry\" A&B&apos;s")
        XCTAssertEqual(yrcDoc.lines.first?.translation, "别<哭>'了")

        let lrcDoc = try parse([
            "code": 200,
            "lrc": ["lyric": "[00:02.00]It&#39;s &amp; don&apos;t"]
        ])
        XCTAssertEqual(lrcDoc.lines.first?.text, "It's & don't")
    }

    func testLRCFallsBackFromMalformedYRCAndExpandsRepeatedTimestamps() throws {
        let data: [String: Any] = [
            "code": 200,
            "yrc": ["lyric": "[10000,2000](400,2,0)bad"],
            "lrc": ["lyric": "[offset:100]\n[ar:artist]\n[00:10.23][00:20.23]Repeat [00:42]\n[00:21.1]  "],
            "tlyric": ["lyric": "[00:10.130]重复"],
        ]
        let output = try parse(data)
        XCTAssertEqual(output.lines.count, 2)
        XCTAssertEqual(output.wordTiming, .none)
        XCTAssertEqual(output.lines[0].time, 10.13, accuracy: 0.00001)
        XCTAssertEqual(output.lines[1].time, 20.13, accuracy: 0.00001)
        XCTAssertEqual(output.lines[0].text, "Repeat [00:42]")
        XCTAssertEqual(output.lines[0].translation, "重复")
        XCTAssertNil(output.lines[1].translation)
        XCTAssertTrue(output.lines[0].words.isEmpty)
        let missing = try parse(["code": 200, "nolyric": true, "lrc": ["lyric": "[00:01]placeholder"]])
        XCTAssertTrue(missing.lines.isEmpty)
    }

    func testSearchChoosesMatchingRecordingAndGetsCoverWhenLyricsAreMissing() async {
        let provider = makeProvider()
        let track = TrackInfo(title: "Example", artist: "Singer", album: "Record", duration: 134,
                              position: 2, state: .playing, source: .netease)
        let document = await provider.lyrics(for: track)
        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertEqual(document.artworkURL?.absoluteString, "https://p1.music.126.net/record-303.jpg")
    }

    func testTitleAndClockWithoutArtistOnlyMatchOneRecordingWithinRoundingError() async {
        let provider = makeProvider()
        func track(duration: Double) -> TrackInfo {
            TrackInfo(title: "Example", artist: "", album: "", duration: duration,
                      position: 2, state: .playing, source: .netease)
        }
        let unique = await provider.lyrics(for: track(duration: 189))
        XCTAssertEqual(unique.lines.first?.text, "Test lyric")
        XCTAssertEqual(unique.artworkURL?.lastPathComponent, "record-404.jpg")

        // Two artists have same-title recordings around 134 seconds.
        let ambiguous = await provider.lyrics(for: track(duration: 134))
        XCTAssertTrue(ambiguous.lines.isEmpty)
        XCTAssertNil(ambiguous.artworkURL)
        let differentLength = await provider.lyrics(for: track(duration: 188))
        XCTAssertTrue(differentLength.lines.isEmpty)
        XCTAssertNil(differentLength.artworkURL)
    }

    func testCoverFailurePreservesPlainLyrics() async {
        let track = TrackInfo(title: "Example", artist: "", album: "", duration: 0, position: 0,
                              state: .playing, source: .netease, sourceTrackID: "503")
        let document = await makeProvider().lyrics(for: track)
        XCTAssertNil(document.artworkURL)
        XCTAssertEqual(document.plainText, "first line\nsecond line")
        XCTAssertFalse(document.isSynced)
        XCTAssertTrue(document.lines.isEmpty)
    }

    func testCacheForcedRefreshAndRateLimitWithoutContactingTheNetwork() async {
        let token = UUID().uuidString
        let provider = makeProvider(token: token)
        let cover = URL(string: "https://p1.music.126.net/record.jpg")
        func track(_ id: String) -> TrackInfo {
            TrackInfo(title: "Track", artist: "Singer", album: "", duration: 134,
                      position: 0, state: .playing, source: .netease, sourceTrackID: id, artworkURL: cover)
        }
        let first = await provider.lyrics(for: track("42"))
        XCTAssertEqual(first.lines.first?.text, "Test lyric")
        _ = await provider.lyrics(for: track("42"))
        XCTAssertEqual(FixtureProtocol.requests(token: token), 1)
        _ = await provider.lyrics(for: track("42"), bypassCache: true)
        XCTAssertEqual(FixtureProtocol.requests(token: token), 2)
        let blocked = await provider.lyrics(for: track("429"))
        XCTAssertTrue(blocked.lines.isEmpty)
        _ = await provider.lyrics(for: track("999"), bypassCache: true)
        XCTAssertEqual(FixtureProtocol.requests(token: token), 3)
    }

    func testAppleMusicUsesItsOwnCacheAfterSwitchingBackFromNetEase() async throws {
        let token = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bodies = root.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LyricsService(provider: AppleMusicCacheLyricsProvider(cacheDirectory: root),
                                    netease: makeProvider(token: token))
        let apple = TrackInfo(title: "Track", artist: "Singer", album: "Album", duration: 134,
                              position: 1, state: .playing)
        let netease = TrackInfo(title: apple.title, artist: apple.artist, album: apple.album,
                               duration: apple.duration, position: 1, state: .playing,
                               source: .netease, sourceTrackID: "42",
                               artworkURL: URL(string: "https://p1.music.126.net/record.jpg"))

        let missing = await service.lyrics(for: apple)
        XCTAssertEqual(missing, .empty)
        XCTAssertEqual(FixtureProtocol.requests(token: token), 0)
        let online = await service.lyrics(for: netease)
        XCTAssertEqual(online.lines.first?.text, "Test lyric")
        XCTAssertEqual(FixtureProtocol.requests(token: token), 1)

        let response = #"""
        {"data":[{"attributes":{"name":"Track","artistName":"Singer","albumName":"Album","durationInMillis":134000},
          "relationships":{"syllable-lyrics":{"data":[{"attributes":{"ttmlLocalizations":
          "<tt><body><div><p begin=\"1s\" end=\"2s\"><span begin=\"1s\" end=\"2s\">Cached lyric</span></p></div></body></tt>"}}]}}}]}
        """#
        try Data(response.utf8).write(to: bodies.appendingPathComponent(UUID().uuidString))
        let local = await service.lyrics(for: apple)
        XCTAssertEqual(local.source, "Apple Music")
        XCTAssertEqual(local.lines.first?.text, "Cached lyric")
        XCTAssertEqual(local.wordTiming, .exact)
        XCTAssertEqual(FixtureProtocol.requests(token: token), 1)
    }

    func testPublicSongLookupWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["JFM_NETEASE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set JFM_NETEASE_INTEGRATION=1 for the public NetEase catalogue check")
        }
        let track = TrackInfo(title: "孤勇者", artist: "陈奕迅", album: "", duration: 256,
                              position: 1, state: .playing, source: .netease)
        let document = await NetEaseLyricsProvider().lyrics(for: track)
        XCTAssertTrue(document.isSynced)
        XCTAssertGreaterThan(document.lines.count, 2)
        XCTAssertEqual(document.wordTiming, .exact)
        XCTAssertTrue(document.lines.contains { $0.words.count > 2 })
        XCTAssertEqual(document.artworkURL?.scheme, "https")

        // The public LRC for this recording includes standalone backing vocals.
        let harmonyTrack = TrackInfo(title: "Die With A Smile", artist: "Lady Gaga / Bruno Mars", album: "", duration: 251,
                                     position: 0, state: .playing, source: .netease, sourceTrackID: "2617944302")
        let harmony = await NetEaseLyricsProvider().lyrics(for: harmonyTrack)
        XCTAssertTrue(harmony.isSynced)
        XCTAssertTrue(harmony.floatingLines.contains { $0.vocalRole.isHarmony && !$0.text.isEmpty })

        let provider = NetEaseLyricsProvider()
        let nameLabels = TrackInfo(title: "飞云之下", artist: "韩红 / 林俊杰", album: "", duration: 265,
                                   position: 0, state: .playing, source: .netease, sourceTrackID: "554242032")
        let namedDuet = await provider.lyrics(for: nameLabels)
        XCTAssertTrue(namedDuet.lines.contains { $0.vocalRole == .partner })

        let sectionLabels = TrackInfo(title: "今天你要嫁给我", artist: "陶喆 / 蔡依林", album: "", duration: 270,
                                      position: 0, state: .playing, source: .netease, sourceTrackID: "150422")
        let timedDuet = await provider.lyrics(for: sectionLabels)
        XCTAssertTrue(timedDuet.lines.contains { $0.vocalRole == .partner && !$0.words.isEmpty })
    }

    private func parse(_ object: [String: Any], artists: [String] = []) throws -> LyricsDocument {
        let data = try JSONSerialization.data(withJSONObject: object)
        let payload = try JSONDecoder().decode(NetEaseLyricParser.Payload.self, from: data)
        return NetEaseLyricParser.document(payload, artworkURL: nil, artists: artists)
    }

    private func makeProvider(token: String = UUID().uuidString) -> NetEaseLyricsProvider {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["X-Fixture-ID": token]
        config.protocolClasses = [FixtureProtocol.self]
        return NetEaseLyricsProvider(session: URLSession(configuration: config))
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func requests(token: String) -> Int { lock.withLock { counts[token, default: 0] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if let token = request.value(forHTTPHeaderField: "X-Fixture-ID") {
            Self.lock.withLock { Self.counts[token, default: 0] += 1 }
        }
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = fields.first { $0.name == "id" }?.value
        var status = 200
        var object: [String: Any] = ["code": 200]
        switch url.path {
        case "/api/search/get/web":
            let songs: [[String: Any]] = [(101, "Example (Live)", "Singer", 134000),
                                          (202, "Example", "Other", 134000), (404, "Example", "Singer", 190000),
                                          (303, "Example", "Singer", 134175)].map { id, name, artist, duration in
                ["id": id, "name": name, "artists": [["name": artist]], "duration": duration, "album": ["name": "Record"]]
            }
            object["result"] = ["songs": songs]
        case "/api/song/detail":
            let ids = fields.first { $0.name == "ids" }?.value
            let value = Int((ids ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) ?? 0
            object["songs"] = [["id": value, "name": "Example", "album": ["picUrl": "http://p1.music.126.net/record-\(value).jpg"]]]
            if value == 503 { status = 503 }
        case "/api/song/lyric/v1" where id == "429":
            status = 429
        case "/api/song/lyric/v1" where id == "303":
            object["uncollected"] = true
        case "/api/song/lyric/v1" where id == "503":
            object["lrc"] = ["lyric": "[ar:Artist]\nfirst line\nsecond line"]
        case "/api/song/lyric/v1":
            object["lrc"] = ["lyric": "[00:01.020]Test lyric"]
        default: status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
