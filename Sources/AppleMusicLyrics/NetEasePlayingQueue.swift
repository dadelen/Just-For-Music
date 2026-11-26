import Foundation

struct NetEaseQueueSong {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: URL?
    fileprivate let artistNames: [String]

    static func parse(_ track: [String: Any]) -> Self? {
        guard let id = track["id"] as? String ?? (track["id"] as? NSNumber)?.stringValue,
              let numericID = Int64(id), numericID > 0,
              let title = track["name"] as? String, !title.isEmpty,
              let milliseconds = (track["duration"] as? NSNumber)?.doubleValue,
              milliseconds.isFinite, milliseconds > 0 else { return nil }
        let artists = (track["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let album = track["album"] as? [String: Any]
        let rawCover = (album?["picUrl"] as? String) ?? (album?["cover"] as? String)
        return Self(id: String(numericID), title: title, artist: artists.joined(separator: " / "),
                    album: album?["name"] as? String ?? "", duration: milliseconds / 1000,
                    artworkURL: NetEaseLyricsProvider.coverURL(rawCover), artistNames: artists)
    }
}

/// Enrich a song already identified in the player. Queue order carries no playback state.
final class NetEasePlayingQueue {
    private let locations: [URL]
    private struct FileVersion: Equatable {
        let url: URL
        let date: Date
        let size: Int
    }
    private var version: FileVersion?
    private var songs: [NetEaseQueueSong] = []

    init(locations: [URL]? = nil) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let suffix = "Documents/storage/file_storage/webdata/file/playingList"
        self.locations = locations ?? [
            library.appendingPathComponent("Application Support/com.netease.163music/" + suffix),
            library.appendingPathComponent("Containers/com.netease.163music/Data/" + suffix)
        ]
    }

    func song(id: String?, title: String, artist: String, duration: TimeInterval? = nil) -> NetEaseQueueSong? {
        refresh()
        if let id, !id.isEmpty { return songs.first { $0.id == id } }
        let titleKey = Self.key(title)
        let artistKey = Self.key(artist)
        guard !titleKey.isEmpty else { return nil }
        var match: NetEaseQueueSong?
        for song in songs where Self.key(song.title) == titleKey {
            if let duration, abs(song.duration - duration) > 2 { continue }
            if !artistKey.isEmpty, Self.key(song.artist) != artistKey,
               !song.artistNames.contains(where: { Self.key($0) == artistKey }) { continue }
            if let match, match.id != song.id { return nil }
            match = song
        }
        return match
    }

    private static func key(_ name: String) -> String {
        name.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

    private func refresh() {
        let files = locations.compactMap { url -> FileVersion? in
            var mutableURL = url
            mutableURL.removeAllCachedResourceValues()
            guard let values = try? mutableURL.resourceValues(forKeys: Self.resourceKeys),
                  let date = values.contentModificationDate, let size = values.fileSize,
                  size > 0, size <= 32 * 1024 * 1024 else { return nil }
            return FileVersion(url: url, date: date, size: size)
        }
        guard let current = files.max(by: { $0.date < $1.date }) else {
            version = nil
            songs = []
            return
        }
        guard current != version else { return }
        // A partial write can be retried at the next sample without returning stale entries.
        songs = []
        version = nil
        guard let data = try? Data(contentsOf: current.url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["list"] as? [[String: Any]] else { return }
        songs = list.compactMap { ($0["track"] as? [String: Any]).flatMap(NetEaseQueueSong.parse) }
        version = current
    }
}
