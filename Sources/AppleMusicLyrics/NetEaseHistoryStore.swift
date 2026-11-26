import Foundation
import SQLite3

struct NetEaseHistoryEntry: Equatable {
    let id: String
    /// Unix epoch timestamp in seconds when NetEase started playing this track.
    let playtime: TimeInterval
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: URL?
}

/// Read-only reader for NetEase Desktop's local playback history table (`historyTracks`).
/// Used for song metadata only. Cache by file version so polling incurs no SQLite I/O
/// while the file is unchanged.
final class NetEaseHistoryStore {
    private let locations: [URL]
    private struct FileVersion: Equatable {
        let url: URL
        let date: Date
        let size: Int
        let walDate: Date?
        let walSize: Int?
    }
    private var version: FileVersion?
    private var cachedEntry: NetEaseHistoryEntry?

    init(locations: [URL]? = nil) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let suffix = "Documents/storage/sqlite_storage.sqlite3"
        self.locations = locations ?? [
            library.appendingPathComponent("Application Support/com.netease.163music/" + suffix),
            library.appendingPathComponent("Containers/com.netease.163music/Data/" + suffix)
        ]
    }

    func latestSong() -> NetEaseHistoryEntry? {
        let files = locations.compactMap { Self.fileVersion(for: $0) }
        guard let current = files.max(by: {
            max($0.date, $0.walDate ?? .distantPast) < max($1.date, $1.walDate ?? .distantPast)
        }) else {
            version = nil
            cachedEntry = nil
            return nil
        }
        if current == version { return cachedEntry }
        let loaded = Self.readLatest(from: current.url)
        if loaded != nil {
            cachedEntry = loaded
            version = current
        }
        return loaded ?? cachedEntry
    }

    private static let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

    private static func fileVersion(for url: URL) -> FileVersion? {
        var mutableURL = url
        mutableURL.removeAllCachedResourceValues()
        guard let values = try? mutableURL.resourceValues(forKeys: resourceKeys),
              let date = values.contentModificationDate,
              let size = values.fileSize, size > 0 else { return nil }
        var walURL = URL(fileURLWithPath: url.path + "-wal")
        walURL.removeAllCachedResourceValues()
        let walValues = try? walURL.resourceValues(forKeys: resourceKeys)
        return FileVersion(
            url: url,
            date: date,
            size: size,
            walDate: walValues?.contentModificationDate,
            walSize: walValues?.fileSize
        )
    }

    private static func readLatest(from url: URL) -> NetEaseHistoryEntry? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        let query = "SELECT playtime, id, jsonStr FROM historyTracks ORDER BY playtime DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let playtimeMS = sqlite3_column_int64(statement, 0)
        let rowID = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        guard let jsonCString = sqlite3_column_text(statement, 2) else { return nil }
        let jsonString = String(cString: jsonCString)
        return parse(playtimeMS: playtimeMS, rowID: rowID, jsonString: jsonString)
    }

    static func parse(playtimeMS: Int64, rowID: String, jsonString: String) -> NetEaseHistoryEntry? {
        guard playtimeMS > 0,
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rawID = (object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue ?? rowID
        guard let numericID = Int64(rawID), numericID > 0,
              let title = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let durationMS = (object["duration"] as? NSNumber)?.doubleValue,
              durationMS.isFinite, durationMS > 0 else { return nil }
        let artists = (object["artists"] as? [[String: Any]])?
            .compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let albumObject = object["album"] as? [String: Any]
        let album = (albumObject?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawCover = (albumObject?["picUrl"] as? String) ?? (albumObject?["cover"] as? String)
        let artworkURL = NetEaseLyricsProvider.coverURL(rawCover)
        return NetEaseHistoryEntry(
            id: rawID,
            playtime: Double(playtimeMS) / 1000.0,
            title: title,
            artist: artists.joined(separator: " / "),
            album: album,
            duration: durationMS / 1000.0,
            artworkURL: artworkURL
        )
    }
}
