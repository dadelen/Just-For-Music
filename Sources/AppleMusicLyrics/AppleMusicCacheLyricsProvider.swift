import Foundation
import os
import SQLite3

/// Reads the catalog responses already downloaded by Music.app. This provider
/// never uses Apple account credentials and never makes a network request.
final class AppleMusicCacheLyricsProvider: @unchecked Sendable {
    enum CacheAccess: Equatable, Sendable {
        case readable
        case missing
        case denied
    }

    struct CacheRevision: Equatable {
        let databaseModified: Date?
        let journalModified: Date?
        let bodiesModified: Date?
    }

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let databaseURL: URL
    private let journalURL: URL
    private let preferredLanguages: [String]
    private struct DirectoryMiss: Sendable {
        let modified: Date?
        let retryAt: TimeInterval
    }

    private let directoryMisses = OSAllocatedUnfairLock(initialState: [String: DirectoryMiss]())
    private let decodedResponses = NSCache<NSURL, CatalogResponseBox>()
    private let maximumCandidates = 160
    private let logger = DiagnosticLogger.shared
    private let metadataMatcher = TrackMetadataMatcher()

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.fileManager = fileManager
        self.preferredLanguages = preferredLanguages
        let root = cacheDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
        self.cacheDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("Cache.db")
        self.journalURL = root.appendingPathComponent("Cache.db-wal")
        self.decodedResponses.countLimit = 256
    }

    func cacheAccess() -> CacheAccess {
        // A metadata check can succeed even when the system rejects opening the file.
        var indexDenied = false
        do {
            let handle = try FileHandle(forReadingFrom: databaseURL)
            try? handle.close()
            return .readable
        } catch {
            indexDenied = Self.isPermissionError(error as NSError)
        }

        do {
            _ = try fileManager.contentsOfDirectory(atPath: cacheDirectory.path)
            return .readable
        } catch {
            return indexDenied || Self.isPermissionError(error as NSError) ? .denied : .missing
        }
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.EPERM.rawValue) || error.code == Int(POSIXErrorCode.EACCES.rawValue) {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionError) ?? false
    }

    func cacheRevision() -> CacheRevision {
        func modified(_ url: URL) -> Date? {
            (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return CacheRevision(databaseModified: modified(databaseURL), journalModified: modified(journalURL),
                             bodiesModified: modified(cacheDirectory))
    }

    func lyrics(for track: TrackInfo, recentIndexOnly: Bool = false,
                bypassDirectoryCooldown: Bool = false,
                isCancelled: () -> Bool = { Task.isCancelled }) -> LyricsDocument {
        guard track.source == .appleMusic, !isCancelled() else { return .empty }
        let started = ProcessInfo.processInfo.systemUptime
        logger.info("Lyrics lookup started; track=\(track.displayName); recentIndexOnly=\(recentIndexOnly)")
        let indexed = indexedCandidates(limit: recentIndexOnly ? 24 : maximumCandidates, isCancelled: isCancelled)
        guard !isCancelled() else { return .empty }
        let indexMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        logger.info("Cache index collected; indexed=\(indexed.count); milliseconds=\(indexMilliseconds)")

        typealias Match = (match: TrackMetadataMatch, song: CatalogSong)
        let decoder = JSONDecoder()
        let target = TrackMetadataTarget(track)
        var lessCertain: [Match] = []
        func scan(_ candidates: [CacheCandidate]) -> LyricsDocument? {
            for candidate in candidates {
                guard !isCancelled() else { return nil }
                let response: CatalogResponse?
                switch candidate {
                case .file(let url):
                    let key = url as NSURL
                    let modDate = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                    if !bypassDirectoryCooldown,
                       let cached = decodedResponses.object(forKey: key),
                       cached.modifiedDate == modDate {
                        response = cached.response
                    } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                              let decoded = try? decoder.decode(CatalogResponse.self, from: data) {
                        decodedResponses.setObject(CatalogResponseBox(decoded, modifiedDate: modDate), forKey: key)
                        response = decoded
                    } else {
                        response = nil
                    }
                case .inline(let data):
                    response = try? decoder.decode(CatalogResponse.self, from: data)
                }
                guard let response else { continue }
                let matches: [Match] = response.data.compactMap { song in
                    guard song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations != nil,
                          let match = metadataMatcher.match(song.attributes, to: target) else { return nil }
                    return (match, song)
                }.sorted { $0.match.score > $1.match.score }

                for (match, song) in matches {
                    guard !isCancelled() else { return nil }
                    // Keep the existing strong-match threshold and require usable TTML before stopping.
                    if match.score >= 180 {
                        if let document = parse(song, match: match) { return document }
                    } else if !recentIndexOnly {
                        lessCertain.append((match, song))
                    }
                }
            }
            return nil
        }

        if let document = scan(indexed) { return document }
        guard !recentIndexOnly, !isCancelled() else { return .empty }
        let key = track.identityKey
        // FileManager reads fresh metadata. A retained URL can cache old resource values.
        let directoryModified = (try? fileManager.attributesOfItem(atPath: cacheDirectory.path))?[.modificationDate] as? Date
        let fallbackStarted = ProcessInfo.processInfo.systemUptime
        let shouldScanDirectory = bypassDirectoryCooldown || directoryMisses.withLock { misses in
            guard let miss = misses[key] else { return true }
            return miss.retryAt <= fallbackStarted || miss.modified != directoryModified
        }
        if shouldScanDirectory {
            let fallback = directoryCandidates(excluding: Set(indexed.compactMap(\.fileURL)))
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - fallbackStarted) * 1_000)
            logger.info("Cache directory candidates collected; count=\(fallback.count); milliseconds=\(milliseconds)")
            if let document = scan(fallback) { return document }
        }

        for (match, song) in lessCertain.sorted(by: { $0.match.score > $1.match.score }) {
            guard !isCancelled() else { return .empty }
            if let document = parse(song, match: match) { return document }
        }
        if shouldScanDirectory, !isCancelled() {
            let retryAt = ProcessInfo.processInfo.systemUptime + 60
            directoryMisses.withLock { misses in
                misses = misses.filter { $0.value.retryAt > fallbackStarted }
                if misses.count >= 64, let oldest = misses.min(by: { $0.value.retryAt < $1.value.retryAt })?.key {
                    misses.removeValue(forKey: oldest)
                }
                misses[key] = DirectoryMiss(modified: directoryModified, retryAt: retryAt)
            }
            logger.warning("No usable matching cached lyrics response found")
        }
        return .empty
    }

    private func parse(_ song: CatalogSong, match: TrackMetadataMatch) -> LyricsDocument? {
        logger.info("Lyrics metadata matched; evidence=\(match.evidence)")
        guard let rawTTML = song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations,
              let selection = localizedTTML(from: rawTTML) else {
            logger.warning("Matching response has an unsupported or empty ttmlLocalizations value")
            return nil
        }
        logger.info("Lyrics localization selected; locale=\(selection.locale ?? "unlabeled")")
        let parsed: ParsedAppleTTML
        if let parsedPrimary = selection.parsedPrimary {
            parsed = parsedPrimary
        } else {
            do {
                parsed = try AppleTTMLParser.parse(selection.primaryTTML)
            } catch {
                logger.error("TTML parsing failed: \(error.localizedDescription)")
                return nil
            }
        }
        guard !parsed.lines.isEmpty else {
            logger.warning("TTML parsed successfully but contained no lyric lines")
            return nil
        }
        let enrichedLines = enrich(
            parsed.lines,
            sourceLocale: selection.locale,
            with: selection.alternatives
        )
        let translatedCount = enrichedLines.filter { $0.translation != nil }.count
        let transliteratedCount = enrichedLines.filter { $0.transliteration != nil }.count
        logger.info(
            "Lyrics loaded; lines=\(parsed.lines.count); wordTiming=\(parsed.wordTiming.rawValue); "
                + "translations=\(translatedCount); transliterations=\(transliteratedCount)"
        )

        return LyricsDocument(
            lines: enrichedLines,
            plainText: enrichedLines.map(\.text).joined(separator: "\n"),
            source: "Apple Music",
            isSynced: true,
            wordTiming: parsed.wordTiming,
            artworkURL: song.attributes.artwork?.resolvedURL,
            sourceLanguage: selection.locale
        )
    }

    // MARK: - Cache index

    private func directoryCandidates(excluding indexedPaths: Set<URL>) -> [CacheCandidate] {
        // The database may contain stale paths after a Music or macOS update.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            let fileError = error as NSError
            let underlying = fileError.userInfo[NSUnderlyingErrorKey] as? NSError
            let reason = "\(fileError.domain) (\(fileError.code))"
            let detail = underlying.map { "; underlying=\($0.domain) (\($0.code))" } ?? ""
            logger.warning("Cache data directory is unavailable; path=\(cacheDirectory.path); error=\(reason)\(detail)")
            return []
        }

        return urls
            .compactMap { url -> (URL, Date)? in
                guard !indexedPaths.contains(url), let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maximumCandidates)
            .map { .file($0.0) }
    }

    private func indexedCandidates(limit: Int, isCancelled: () -> Bool) -> [CacheCandidate] {
        guard fileManager.isReadableFile(atPath: databaseURL.path) else { return [] }

        var database: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK, let database else { return [] }

        let query = """
        SELECT d.isDataOnFS, d.receiver_data
        FROM cfurl_cache_response r
        JOIN cfurl_cache_receiver_data d USING(entry_ID)
        WHERE r.request_key LIKE '%syllable-lyrics%'
        ORDER BY r.time_stamp DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
            logger.warning("Cache index is unavailable: \(String(cString: sqlite3_errmsg(database)))")
            return []
        }

        var candidates: [CacheCandidate] = []
        while !isCancelled() {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return candidates }
            guard status == SQLITE_ROW else {
                logger.warning("Cache index read failed: \(String(cString: sqlite3_errmsg(database)))")
                return []
            }
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            let payload = Data(bytes: bytes, count: count)
            switch sqlite3_column_int(statement, 0) {
            case 0: candidates.append(.inline(payload))
            case 1:
                if let name = String(data: payload, encoding: .utf8), let url = cacheFileURL(named: name) {
                    candidates.append(.file(url))
                }
            default: break
            }
        }
        return []
    }

    private func cacheFileURL(named name: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard name.count == 36,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(name, isDirectory: false)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    private func localizedTTML(from value: TTMLLocalizations) -> LocalizedTTMLSelection? {
        let localizations: [String: String]
        switch value {
        case .ttml(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") {
                let locale = TTMLLanguageDetector.language(in: trimmed)
                let normalized = locale.map {
                    LyricsLocaleMatcher.normalizeChineseScript(
                        in: trimmed,
                        selectedLocale: $0,
                        preferredLanguages: preferredLanguages
                    )
                } ?? trimmed
                return LocalizedTTMLSelection(
                    primaryTTML: normalized,
                    locale: locale,
                    alternatives: []
                )
            }
            guard let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return nil
            }
            localizations = decoded
        case .localized(let values):
            localizations = values
        }
        let primaryKeys = localizations.keys.filter {
            let value = $0.lowercased()
            return !["translation", "translit", "roman", "latn"].contains(where: value.contains)
        }
        let candidates = primaryKeys.isEmpty ? Array(localizations.keys) : primaryKeys
        var parsedCandidates: [String: ParsedAppleTTML] = [:]
        let timedKeys = candidates.filter {
            guard let ttml = localizations[$0],
                  let parsed = try? AppleTTMLParser.parse(ttml) else { return false }
            parsedCandidates[$0] = parsed
            return parsed.wordTiming == .exact
        }
        let selectedKey = LyricsLocaleMatcher.bestKey(
            in: timedKeys.isEmpty ? candidates : timedKeys,
            preferredLanguages: preferredLanguages
        )
        guard let key = selectedKey ?? localizations.keys.sorted().first,
              let primary = localizations[key] else { return nil }
        let normalizedPrimary = LyricsLocaleMatcher.normalizeChineseScript(
            in: primary,
            selectedLocale: key,
            preferredLanguages: preferredLanguages
        )
        let alternatives = localizations
            .filter { $0.key != key && $0.value != primary }
            .sorted { $0.key < $1.key }
            .map {
                LocalizedTTMLAlternative(
                    locale: $0.key,
                    ttml: $0.value,
                    parsed: parsedCandidates[$0.key]
                )
            }
        let taggedLanguage = TTMLLanguageDetector.language(in: primary)
        return LocalizedTTMLSelection(
            primaryTTML: normalizedPrimary,
            parsedPrimary: normalizedPrimary == primary ? parsedCandidates[key] : nil,
            locale: LyricsDocument.declaredLanguageCode(taggedLanguage) != nil ? taggedLanguage : key,
            alternatives: alternatives
        )
    }

    private func enrich(
        _ primaryLines: [LyricLine],
        sourceLocale: String?,
        with alternatives: [LocalizedTTMLAlternative]
    ) -> [LyricLine] {
        var translations: [Int: String] = [:]
        var translationLanguages: [Int: String] = [:]
        for (index, line) in primaryLines.enumerated() {
            guard let translation = line.translation,
                  !LyricsLocaleMatcher.isRedundantTranslation(
                    translation, of: line.text, sourceLocale: sourceLocale,
                    translationLocale: line.translationLanguage
                  ) else { continue }
            translations[index] = translation
            translationLanguages[index] = line.translationLanguage
        }
        var transliterations: [Int: String] = [:]

        for alternative in alternatives {
            let parsed = alternative.parsed ?? (try? AppleTTMLParser.parse(alternative.ttml))
            guard let parsed else { continue }
            let normalizedLocale = alternative.locale.lowercased()
            let isTransliteration = normalizedLocale.contains("latn")
                || normalizedLocale.contains("roman")
                || normalizedLocale.contains("translit")

            for (alternativeIndex, alternativeLine) in parsed.lines.enumerated() {
                let index: Int?
                if alternativeIndex < primaryLines.count,
                   abs(primaryLines[alternativeIndex].time - alternativeLine.time) <= 1 {
                    index = alternativeIndex
                } else {
                    index = nearestLineIndex(to: alternativeLine.time, in: primaryLines)
                }
                guard let index,
                      abs(primaryLines[index].time - alternativeLine.time) <= 1,
                      primaryLines[index].text != alternativeLine.text else { continue }
                if isTransliteration {
                    transliterations[index, default: alternativeLine.text] = alternativeLine.text
                } else if translations[index] == nil ||
                            (normalizedLocale.hasPrefix("zh") && translationLanguages[index]?.lowercased().hasPrefix("zh") != true) {
                    guard !LyricsLocaleMatcher.isRedundantTranslation(
                        alternativeLine.text, of: primaryLines[index].text, sourceLocale: sourceLocale,
                        translationLocale: alternative.locale
                    ) else { continue }
                    translations[index] = alternativeLine.text
                    translationLanguages[index] = alternative.locale
                }
            }
        }

        return primaryLines.enumerated().map { index, line in
            LyricLine(
                time: line.time,
                text: line.text,
                words: line.words,
                translation: translations[index],
                transliteration: transliterations[index],
                confirmedEnd: line.confirmedEnd,
                translationLanguage: translationLanguages[index],
                vocalRole: line.vocalRole,
                harmonies: line.harmonies
            )
        }
    }

    // Parser output is sorted by timestamp. Equal distances keep the earlier
    // line, matching the previous linear scan's tie-breaking behavior.
    private func nearestLineIndex(to time: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lines[middle].time < time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound == 0 { return 0 }
        if lowerBound == lines.count { return lines.count - 1 }
        let before = lines[lowerBound - 1].time
        let after = lines[lowerBound].time
        return time - before <= after - time ? lowerBound - 1 : lowerBound
    }
}

private struct TrackMetadataMatch {
    let score: Int
    let evidence: String
}

private struct TrackMetadataTarget {
    let title: ComparableMetadataText
    let artist: ComparableMetadataText
    let album: ComparableMetadataText
    let duration: TimeInterval

    init(_ track: TrackInfo) {
        title = ComparableMetadataText(track.title)
        artist = ComparableMetadataText(track.artist)
        album = ComparableMetadataText(track.album)
        duration = track.duration
    }
}

private struct TrackMetadataMatcher {
    func match(_ song: CatalogSongAttributes, to target: TrackMetadataTarget) -> TrackMetadataMatch? {
        let durationDifference: TimeInterval? = {
            guard target.duration > 0,
                  let duration = song.durationInMillis,
                  duration > 0 else { return nil }
            return abs(Double(duration) / 1000 - target.duration)
        }()
        if let durationDifference, durationDifference > 12 { return nil }

        let candidateTitle = ComparableMetadataText(song.name)
        let titleMatch = target.title.match(candidateTitle)
        guard titleMatch != .none else { return nil }

        let candidateArtist = ComparableMetadataText(song.artistName)
        let artistMatch = target.artist.match(candidateArtist)
        let artistMissing = target.artist.isEmpty || candidateArtist.isEmpty
        let localizedArtist = target.artist.usesDifferentWritingSystem(from: candidateArtist)
        let artistIsTrusted = artistMatch.isStrongIdentity

        let candidateAlbum = ComparableMetadataText(song.albumName ?? "")
        let albumMatch = target.album.match(candidateAlbum)
        let albumIsTrusted = albumMatch.isStrongIdentity

        let durationIsTight = durationDifference.map { $0 <= 2 } == true
        let durationIsNear = durationDifference.map { $0 <= 5 } == true
        let accepted: Bool
        switch titleMatch {
        case .exact, .canonical:
            accepted = artistIsTrusted
                || (durationIsTight && (localizedArtist || artistMissing || albumIsTrusted))
        case .transliterated:
            accepted = durationIsTight && (artistIsTrusted || albumIsTrusted)
        case .contained:
            accepted = durationIsNear && artistIsTrusted
        case .none:
            accepted = false
        }
        guard accepted else { return nil }

        var score = titleMatch.titleScore
        if artistIsTrusted {
            score += artistMatch.identityScore
        } else if localizedArtist {
            score += 10
        } else if !artistMissing {
            score -= 40
        }
        if albumIsTrusted {
            score += albumMatch.albumScore
        }
        if let durationDifference {
            if durationDifference <= 2 { score += 40 }
            else if durationDifference <= 5 { score += 25 }
            else { score += 5 }
        }

        let durationEvidence = durationDifference.map {
            String(format: "%.1fs", $0)
        } ?? "unavailable"
        let artistEvidence = artistIsTrusted
            ? artistMatch.label
            : (localizedArtist ? "localized-writing-system" : "missing")
        return TrackMetadataMatch(
            score: score,
            evidence: "title=\(titleMatch.label); artist=\(artistEvidence); "
                + "album=\(albumMatch.label); durationDelta=\(durationEvidence)"
        )
    }
}

private enum MetadataTextMatch: Equatable {
    case exact
    case canonical
    case transliterated
    case contained
    case none

    var label: String {
        switch self {
        case .exact: return "exact"
        case .canonical: return "cjk-canonical"
        case .transliterated: return "transliterated"
        case .contained: return "contained"
        case .none: return "none"
        }
    }

    var isStrongIdentity: Bool {
        switch self {
        case .exact, .canonical, .transliterated: return true
        case .contained, .none: return false
        }
    }

    var titleScore: Int {
        switch self {
        case .exact: return 100
        case .canonical: return 95
        case .transliterated: return 80
        case .contained: return 45
        case .none: return 0
        }
    }

    var identityScore: Int {
        switch self {
        case .exact: return 45
        case .canonical: return 42
        case .transliterated: return 35
        case .contained: return 20
        case .none: return 0
        }
    }

    var albumScore: Int {
        switch self {
        case .exact: return 20
        case .canonical: return 18
        case .transliterated: return 12
        case .contained: return 6
        case .none: return 0
        }
    }
}

private struct ComparableMetadataText {
    private static let cjkCanonicalTransform = StringTransform("Traditional-Simplified")

    let surface: String
    let cjkCanonical: String
    let transliterated: String
    let containsCJK: Bool
    let containsASCIILatin: Bool

    var isEmpty: Bool { surface.isEmpty }

    init(_ value: String) {
        surface = Self.compact(value, stripsDiacritics: true)
        let canonical = value.applyingTransform(Self.cjkCanonicalTransform, reverse: false) ?? value
        cjkCanonical = Self.compact(canonical, stripsDiacritics: true)
        let latin = canonical.applyingTransform(.toLatin, reverse: false) ?? canonical
        transliterated = Self.compact(latin, stripsDiacritics: false)
        containsCJK = value.unicodeScalars.contains { Self.isCJK($0.value) }
        containsASCIILatin = value.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    func match(_ other: ComparableMetadataText) -> MetadataTextMatch {
        guard !isEmpty, !other.isEmpty else { return .none }
        if surface == other.surface { return .exact }
        if cjkCanonical == other.cjkCanonical { return .canonical }
        let bothUseCJK = containsCJK && other.containsCJK
        if !bothUseCJK,
           !transliterated.isEmpty,
           transliterated == other.transliterated {
            return .transliterated
        }
        if Self.containsEitherDirection(surface, other.surface)
            || Self.containsEitherDirection(cjkCanonical, other.cjkCanonical)
            || (!bothUseCJK
                && Self.containsEitherDirection(transliterated, other.transliterated)) {
            return .contained
        }
        return .none
    }

    func usesDifferentWritingSystem(from other: ComparableMetadataText) -> Bool {
        (containsCJK && other.containsASCIILatin)
            || (containsASCIILatin && other.containsCJK)
    }

    private static func containsEitherDirection(_ lhs: String, _ rhs: String) -> Bool {
        min(lhs.count, rhs.count) >= 3 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func compact(_ value: String, stripsDiacritics: Bool) -> String {
        var options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        if stripsDiacritics { options.insert(.diacriticInsensitive) }
        let folded = value.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }
}

private struct LocalizedTTMLSelection {
    let primaryTTML: String
    let parsedPrimary: ParsedAppleTTML?
    let locale: String?
    let alternatives: [LocalizedTTMLAlternative]

    init(
        primaryTTML: String,
        parsedPrimary: ParsedAppleTTML? = nil,
        locale: String? = nil,
        alternatives: [LocalizedTTMLAlternative]
    ) {
        self.primaryTTML = primaryTTML
        self.parsedPrimary = parsedPrimary
        self.locale = locale
        self.alternatives = alternatives
    }
}

private enum LyricsLocaleMatcher {
    private static let traditionalToSimplified = StringTransform("Traditional-Simplified")
    private static let simplifiedToTraditional = StringTransform("Simplified-Traditional")

    static func isRedundantTranslation(_ translation: String, of original: String,
                                       sourceLocale: String?, translationLocale: String?) -> Bool {
        let originalText = original.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let translatedText = translation.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if originalText == translatedText { return true }
        guard sourceLocale.map(LanguageTag.init)?.language == "zh",
              translationLocale.map(LanguageTag.init)?.language == "zh",
              let simplifiedOriginal = originalText.applyingTransform(traditionalToSimplified, reverse: false),
              let simplifiedTranslation = translatedText.applyingTransform(traditionalToSimplified, reverse: false)
        else { return false }
        return simplifiedOriginal == simplifiedTranslation
    }

    static func bestKey<S: Sequence>(
        in keys: S,
        preferredLanguages: [String]
    ) -> String? where S.Element == String {
        let sortedKeys = keys.sorted()
        let candidates = sortedKeys.map { ($0, LanguageTag($0)) }

        for preferredIdentifier in preferredLanguages {
            let preferred = LanguageTag(preferredIdentifier)
            guard !preferred.language.isEmpty else { continue }
            let matches = candidates.compactMap { key, candidate -> (String, Int)? in
                guard candidate.language == preferred.language else { return nil }
                return (key, score(candidate, against: preferred))
            }
            if let best = matches.max(by: {
                $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 < $1.1
            }) {
                return best.0
            }
        }
        return nil
    }

    static func normalizeChineseScript(
        in ttml: String,
        selectedLocale: String,
        preferredLanguages: [String]
    ) -> String {
        let selected = LanguageTag(selectedLocale)
        guard selected.language == "zh",
              let preferred = preferredLanguages
                .map(LanguageTag.init)
                .first(where: { $0.language == "zh" }),
              let script = preferred.inferredChineseScript else { return ttml }

        let transform = script == "hans"
            ? traditionalToSimplified
            : simplifiedToTraditional
        return ttml.applyingTransform(transform, reverse: false) ?? ttml
    }

    private static func score(_ candidate: LanguageTag, against preferred: LanguageTag) -> Int {
        if candidate.normalized == preferred.normalized { return 1_000 }

        var score = 100
        let preferredScript = preferred.inferredChineseScript ?? preferred.script
        let candidateScript = candidate.inferredChineseScript ?? candidate.script
        if let preferredScript {
            if candidateScript == preferredScript {
                score += 300
            } else if candidateScript == nil {
                score += 100
            } else {
                score -= 300
            }
        } else if candidateScript == nil {
            score += 100
        }
        if let preferredRegion = preferred.region, candidate.region == preferredRegion {
            score += 40
        }
        return score
    }

    private struct LanguageTag {
        let normalized: String
        let language: String
        let script: String?
        let region: String?

        init(_ identifier: String) {
            normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            let parts = normalized.split(separator: "-").map(String.init)
            language = parts.first ?? ""
            script = parts.dropFirst().first {
                $0.count == 4 && $0.allSatisfy(\.isLetter)
            }
            region = parts.dropFirst().first {
                ($0.count == 2 && $0.allSatisfy(\.isLetter))
                    || ($0.count == 3 && $0.allSatisfy(\.isNumber))
            }
        }

        var inferredChineseScript: String? {
            guard language == "zh" else { return nil }
            if script == "hans" || script == "hant" { return script }
            switch region {
            case "cn", "sg", "my": return "hans"
            case "tw", "hk", "mo": return "hant"
            default: return nil
            }
        }
    }
}

private enum TTMLLanguageDetector {
    static func language(in ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = RootElementDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.language
    }

    private final class RootElementDelegate: NSObject, XMLParserDelegate {
        var language: String?
        private var foundRoot = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard !foundRoot else { return }
            foundRoot = true
            language = attributeDict["xml:lang"] ?? attributeDict["lang"]
            parser.abortParsing()
        }
    }
}

private struct LocalizedTTMLAlternative {
    let locale: String
    let ttml: String
    let parsed: ParsedAppleTTML?
}

private enum CacheCandidate {
    case file(URL)
    case inline(Data)

    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }
}

private final class CatalogResponseBox: @unchecked Sendable {
    let response: CatalogResponse
    let modifiedDate: Date?
    init(_ response: CatalogResponse, modifiedDate: Date?) {
        self.response = response
        self.modifiedDate = modifiedDate
    }
}

private struct CatalogResponse: Decodable {
    let data: [CatalogSong]
}

private struct CatalogSong: Decodable {
    let attributes: CatalogSongAttributes
    let relationships: CatalogRelationships?
}

private struct CatalogSongAttributes: Decodable {
    let name: String
    let artistName: String
    let albumName: String?
    let durationInMillis: Int?
    let artwork: CatalogArtwork?
}

private struct CatalogArtwork: Decodable {
    let url: String

    var resolvedURL: URL? {
        URL(
            string: url
                .replacingOccurrences(of: "{w}", with: "320")
                .replacingOccurrences(of: "{h}", with: "320")
                .replacingOccurrences(of: "{c}", with: "bb")
                .replacingOccurrences(of: "{f}", with: "jpg")
        )
    }
}

private struct CatalogRelationships: Decodable {
    let syllableLyrics: CatalogRelationship?

    enum CodingKeys: String, CodingKey {
        case syllableLyrics = "syllable-lyrics"
    }
}

private struct CatalogRelationship: Decodable {
    let data: [CatalogLyric]
}

private struct CatalogLyric: Decodable {
    let attributes: CatalogLyricAttributes
}

private struct CatalogLyricAttributes: Decodable {
    let ttmlLocalizations: TTMLLocalizations?
}

private enum TTMLLocalizations: Decodable {
    case ttml(String)
    case localized([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .ttml(value)
        } else {
            self = .localized(try container.decode([String: String].self))
        }
    }
}
