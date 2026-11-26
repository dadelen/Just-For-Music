import Foundation

/// Reads public NetEase catalogue metadata. No account, cookies, audio or signed client requests.
actor NetEaseLyricsProvider {
    private struct Artist: Decodable { let name: String }
    private struct Album: Decodable { let name: String?; let picUrl: String? }
    private struct Song: Decodable {
        let id: Int64
        let name: String
        let artists: [Artist]?
        let album: Album?
        let duration: Double?
    }
    private struct Search: Decodable {
        struct Results: Decodable { let songs: [Song]? }
        let result: Results?
    }
    private struct Detail: Decodable { let songs: [Song]? }
    private struct Status: Decodable { let code: Int }
    private struct Entry {
        let key: String
        let document: LyricsDocument
        let expires: Date
    }

    private let session: URLSession
    private var cache: [Entry] = []
    private var nextRequest = Date.distantPast
    private var limitedUntil = Date.distantPast

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 9
        self.session = session ?? URLSession(configuration: configuration, delegate: NetEaseRedirectPolicy(),
                                             delegateQueue: nil)
    }

    func lyrics(for track: TrackInfo, bypassCache: Bool = false) async -> LyricsDocument {
        guard track.source == .netease, !Task.isCancelled else { return .empty }
        let key = track.identityKey
        let now = Date()
        cache.removeAll { $0.expires <= now }
        if !bypassCache, let cached = cache.last(where: { $0.key == key }) { return cached.document }
        var cover = track.artworkURL
        var document = NetEaseLyricParser.empty(artworkURL: cover)
        guard now >= limitedUntil else { return document }
        do {
            let id: Int64
            var artists = track.artist.components(separatedBy: " / ").filter { !$0.isEmpty }
            if let raw = track.sourceTrackID, let knownID = Int64(raw), knownID > 0 {
                id = knownID
            } else {
                let keywords = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " ")
                guard !track.title.isEmpty else { return document }
                let search: Search = try await get("/api/search/get/web",
                                                    ["s": keywords, "type": "1", "limit": "12", "offset": "0"])
                guard let song = bestSong(search.result?.songs ?? [], for: track) else {
                    DiagnosticLogger.shared.warning("NetEase song search found no match; track=\(track.displayName)")
                    store(document, key: key, seconds: 45)
                    return document
                }
                id = song.id
                artists = song.artists?.map(\.name) ?? artists
                cover = cover ?? Self.coverURL(song.album?.picUrl)
            }
            document = NetEaseLyricParser.empty(artworkURL: cover)
            let payload: NetEaseLyricParser.Payload = try await get("/api/song/lyric/v1", [
                "id": String(id), "lv": "0", "tv": "0", "rv": "0", "yv": "0", "ytv": "0", "yrv": "0"
            ])
            if cover == nil {
                // Search results frequently contain only picId. The detail response has the actual CDN URL.
                let detail: Detail? = try? await get("/api/song/detail", ["ids": "[\(id)]"])
                if let song = detail?.songs?.first(where: { $0.id == id }) {
                    cover = Self.coverURL(song.album?.picUrl)
                    artists = song.artists?.map(\.name) ?? artists
                }
            }
            try Task.checkCancellation()
            document = NetEaseLyricParser.document(payload, artworkURL: cover, artists: artists)
            DiagnosticLogger.shared.info(
                "NetEase lyrics loaded; id=\(id); lines=\(document.lines.count); "
                    + "wordTiming=\(document.wordTiming.rawValue); plain=\(document.plainText != nil)"
            )
            store(document, key: key, seconds: document.lines.isEmpty && document.plainText == nil ? 120 : 3600)
        } catch {
            guard !Task.isCancelled else { return .empty }
            DiagnosticLogger.shared.warning(
                "NetEase lyrics request failed; track=\(track.displayName); error=\(error.localizedDescription)"
            )
            store(document, key: key, seconds: 12)
        }
        return document
    }

    private func store(_ document: LyricsDocument, key: String, seconds: TimeInterval) {
        cache.removeAll { $0.key == key }
        cache.append(Entry(key: key, document: document, expires: Date().addingTimeInterval(seconds)))
        if cache.count > 32 { cache.removeFirst() }
    }

    private func bestSong(_ songs: [Song], for track: TrackInfo) -> Song? {
        let title = Self.canonical(track.title)
        let artist = Self.canonical(track.artist)
        let artistParts = Set(track.artist.components(separatedBy: CharacterSet(charactersIn: "/,，、;&＆·•"))
            .map(Self.canonical).filter { !$0.isEmpty })
        let album = Self.canonical(track.album)
        let exactTitles = songs.filter { $0.id > 0 && !title.isEmpty && Self.canonical($0.name) == title }
        if artist.isEmpty && album.isEmpty {
            // Some playback bars expose just a title and a whole-second clock.
            // A second recording close in length makes that evidence ambiguous.
            guard track.duration > 0, exactTitles.allSatisfy({ ($0.duration ?? 0) > 0 }) else { return nil }
            let close = exactTitles.filter { song in
                guard let duration = song.duration, duration > 0 else { return false }
                return abs(duration / 1000 - track.duration) <= 3
            }
            guard close.count == 1, let song = close.first, let duration = song.duration,
                  abs(duration / 1000 - track.duration) <= 1 else { return nil }
            return song
        }
        var best: (song: Song, score: Double)?
        for song in exactTitles {
            let names = (song.artists ?? []).map { Self.canonical($0.name) }.filter { !$0.isEmpty }
            let fullArtist = !artist.isEmpty && (names.contains(artist) || names.joined() == artist)
            let partialArtist = !artistParts.isDisjoint(with: names)
            let albumMatches = !album.isEmpty && album == Self.canonical(song.album?.name ?? "")
            let seconds = (song.duration ?? 0) / 1000
            let hasDuration = track.duration > 0 && seconds > 0
            let delta = hasDuration ? abs(seconds - track.duration) : 0
            guard !hasDuration || delta <= 3,
                  fullArtist || partialArtist || (artist.isEmpty && albumMatches && hasDuration),
                  hasDuration || albumMatches || album.isEmpty else { continue }
            let score = (fullArtist ? 8.0 : 0) + (albumMatches ? 6.0 : 0) + (hasDuration ? 4.0 - delta : 0)
            if score > (best?.score ?? -.infinity) { best = (song, score) }
        }
        return best?.song
    }

    private static func canonical(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    static func coverURL(_ raw: String?) -> URL? {
        guard let raw, var components = URLComponents(string: raw),
              let host = components.host?.lowercased(), host.hasSuffix(".music.126.net"),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    private func get<T: Decodable>(_ path: String, _ fields: [String: String]) async throws -> T {
        while Date() < nextRequest {
            let interval = max(0, nextRequest.timeIntervalSinceNow)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        try Task.checkCancellation()
        guard Date() >= limitedUntil else { throw URLError(.resourceUnavailable) }
        nextRequest = Date().addingTimeInterval(0.15)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = path
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")) ?? 60
            limitedUntil = max(limitedUntil, Date().addingTimeInterval(delay))
        }
        guard http.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        let status = try decoder.decode(Status.self, from: data)
        if status.code == 429 || status.code == -460 {
            limitedUntil = max(limitedUntil, Date().addingTimeInterval(60))
        }
        guard status.code == 200 else { throw URLError(.resourceUnavailable) }
        return try decoder.decode(T.self, from: data)
    }

    private static func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(seconds, 1) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(1, $0.timeIntervalSinceNow) }
    }
}

private final class NetEaseRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host?.lowercased() == "music.163.com"
            && url?.port == nil && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}
