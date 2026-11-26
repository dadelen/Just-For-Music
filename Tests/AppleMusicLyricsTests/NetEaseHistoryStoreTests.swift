import Foundation
import SQLite3
import XCTest
@testable import AppleMusicLyrics

final class NetEaseHistoryStoreTests: XCTestCase {
    func testReadsLatestHistoryTrackUpgradesCoverAndRefreshesOnInsert() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("sqlite_storage.sqlite3")

        try execute(dbURL: dbURL, sql: """
            CREATE TABLE historyTracks (playtime BIGINT NULL, id VARCHAR(40) NOT NULL, jsonStr TEXT NULL, PRIMARY KEY (id));
            """)
        try insertTrack(
            dbURL: dbURL, playtimeMS: 1_700_000_000_000, id: "150665",
            json: [
                "id": "150665",
                "name": "是是非非",
                "duration": 247_906,
                "artists": [["name": "陶喆"], ["name": "Guest"]],
                "album": ["name": "David Tao", "picUrl": "http://p3.music.126.net/test-cover.jpg"]
            ]
        )

        let store = NetEaseHistoryStore(locations: [dbURL])
        let first = try XCTUnwrap(store.latestSong())
        XCTAssertEqual(first.id, "150665")
        XCTAssertEqual(first.title, "是是非非")
        XCTAssertEqual(first.artist, "陶喆 / Guest")
        XCTAssertEqual(first.album, "David Tao")
        XCTAssertEqual(first.duration, 247.906, accuracy: 0.001)
        XCTAssertEqual(first.playtime, 1_700_000_000.0, accuracy: 0.001)
        XCTAssertEqual(first.artworkURL?.absoluteString, "https://p3.music.126.net/test-cover.jpg")

        // Insert a newer song and touch modification time to guarantee cache invalidation.
        try insertTrack(
            dbURL: dbURL, playtimeMS: 1_700_000_250_000, id: "1712095",
            json: [
                "id": "1712095",
                "name": "ms.philadelphia",
                "duration": 234_919,
                "artists": [["name": "Musiq Soulchild"]],
                "album": ["name": "Luvanmusiq", "picUrl": "https://evil.example.com/bad.jpg"]
            ]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: dbURL.path
        )

        let second = try XCTUnwrap(store.latestSong())
        XCTAssertEqual(second.id, "1712095")
        XCTAssertEqual(second.title, "ms.philadelphia")
        XCTAssertNil(second.artworkURL)
    }

    private func execute(dbURL: URL, sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func insertTrack(dbURL: URL, playtimeMS: Int64, id: String, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO historyTracks (playtime, id, jsonStr) VALUES (?, ?, ?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, playtimeMS)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 3, (text as NSString).utf8String, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
}
