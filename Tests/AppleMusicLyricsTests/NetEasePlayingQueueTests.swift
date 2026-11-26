import XCTest
@testable import AppleMusicLyrics

final class NetEasePlayingQueueTests: XCTestCase {
    func testMatchesObservedSongAcrossQueueUpdatesAndRejectsAmbiguousTitles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("playingList")
        let queue = NetEasePlayingQueue(locations: [url])
        func write(_ tracks: [[String: Any]]) throws {
            let data = try JSONSerialization.data(withJSONObject: ["list": tracks.map { ["track": $0] }])
            try data.write(to: url, options: .atomic)
        }
        let first: [String: Any] = ["id": "318", "name": "Same Title", "duration": 203_200,
            "artists": [["name": "Artist A"], ["name": "Artist B"]],
            "album": ["name": "Album A", "picUrl": "http://p3.music.126.net/album-a.jpg"]]
        let second: [String: Any] = ["id": 732, "name": "Same Title", "duration": 209_000,
            "artists": [["name": "Artist C"]]]
        try write([first, second])
        XCTAssertNil(queue.song(id: nil, title: "", artist: ""))
        XCTAssertNil(queue.song(id: nil, title: "Same Title", artist: ""))
        XCTAssertNil(queue.song(id: "999", title: "Same Title", artist: "Artist B"))
        let match = try XCTUnwrap(queue.song(id: nil, title: "Ｓａｍｅ Title", artist: "Artist B"))
        XCTAssertEqual(match.id, "318")
        XCTAssertEqual(match.artist, "Artist A / Artist B")
        XCTAssertEqual(match.album, "Album A")
        XCTAssertEqual(match.duration, 203.2)
        XCTAssertEqual(match.artworkURL?.absoluteString, "https://p3.music.126.net/album-a.jpg")
        XCTAssertEqual(queue.song(id: nil, title: "Same Title", artist: "", duration: 210)?.id, "732")
        XCTAssertNil(queue.song(id: nil, title: "Same Title", artist: "Artist B", duration: 210))

        try write([second])
        XCTAssertEqual(queue.song(id: nil, title: "Same Title", artist: "")?.id, "732")
        try Data("partial".utf8).write(to: url)
        XCTAssertNil(queue.song(id: "732", title: "Same Title", artist: ""))
    }
}
