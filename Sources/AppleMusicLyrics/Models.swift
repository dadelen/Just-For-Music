import Foundation

enum PlayerState: String, Equatable, Sendable {
    case playing
    case paused
    case stopped
    case unknown

    init(appleScriptValue: String) {
        switch appleScriptValue.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

struct TrackInfo: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    /// A calibrated position's origin in Core Animation's monotonic clock.
    let positionSampledAt: TimeInterval?
    /// Rate of the estimated position between calibrated samples.
    let positionRate: Double
    let state: PlayerState
    let bpm: Int?
    let source: PlaybackSource
    let sourceTrackID: String?
    let artworkURL: URL?
    let canSeek: Bool
    let identityKey: String

    init(title: String, artist: String, album: String, duration: TimeInterval,
         position: TimeInterval, state: PlayerState, bpm: Int? = nil,
         source: PlaybackSource = .appleMusic, sourceTrackID: String? = nil, artworkURL: URL? = nil,
         canSeek: Bool = true, positionSampledAt: TimeInterval? = nil, positionRate: Double = 1) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.positionSampledAt = positionSampledAt
        self.positionRate = positionRate
        self.state = state
        self.bpm = bpm
        self.source = source
        self.sourceTrackID = sourceTrackID
        self.artworkURL = artworkURL
        self.canSeek = canSeek
        let metadataKey = "\(artist.lowercased())|\(title.lowercased())|\(album.lowercased())|\(Int(duration.rounded()))"
        // Preserve existing Apple Music translation and artwork cache keys.
        switch source {
        case .appleMusic: identityKey = metadataKey
        case .netease: identityKey = "netease:" + (sourceTrackID.map { "id:\($0)" } ?? "metadata:\(metadataKey)")
        }
    }

    var displayName: String {
        if artist.isEmpty {
            return title
        }
        return "\(title) — \(artist)"
    }
}

/// One singable unit (character for CJK, word/syllable chunk for Latin).
struct LyricWord: Equatable, Sendable {
    let text: String
    /// Absolute start time in seconds.
    let start: TimeInterval
    /// Absolute end time in seconds.
    let end: TimeInterval
}

enum LyricVocalRole: Equatable, Sendable {
    case lead
    case partner
    case leadHarmony
    case partnerHarmony

    var isHarmony: Bool { self == .leadHarmony || self == .partnerHarmony }
    var isRightAligned: Bool { self == .partner || self == .leadHarmony }
    var harmonyRole: Self { isRightAligned ? .partnerHarmony : .leadHarmony }
}

struct LyricHarmony: Equatable, Sendable {
    let time: TimeInterval
    let words: [LyricWord]

    var text: String { words.map(\.text).joined() }
}

struct LyricLine: Equatable, Sendable, Identifiable {
    let id: String
    let time: TimeInterval
    let text: String
    /// Per-unit timings for karaoke highlighting.
    let words: [LyricWord]
    /// Optional localized meaning aligned to this line.
    let translation: String?
    /// Optional phonetic/romanized reading aligned to this line.
    let transliteration: String?
    let confirmedEnd: TimeInterval?
    let translationLanguage: String?
    let isGap: Bool
    let isMachineTranslation: Bool
    let vocalRole: LyricVocalRole
    let isRightAligned: Bool
    let harmonies: [LyricHarmony]

    var hasPreferredOriginalTranslation: Bool {
        guard !isMachineTranslation,
              let translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return translationLanguage?.lowercased().hasPrefix("zh") ?? true
    }

    init(
        time: TimeInterval,
        text: String,
        words: [LyricWord] = [],
        translation: String? = nil,
        transliteration: String? = nil,
        confirmedEnd: TimeInterval? = nil,
        translationLanguage: String? = nil,
        isGap: Bool = false,
        isMachineTranslation: Bool = false,
        vocalRole: LyricVocalRole = .lead,
        isRightAligned: Bool? = nil,
        harmonies: [LyricHarmony] = []
    ) {
        self.id = "\(time)-\(text.hashValue)"
        self.time = time
        self.text = text
        self.words = words
        self.translation = translation
        self.transliteration = transliteration
        self.confirmedEnd = confirmedEnd
        self.translationLanguage = translationLanguage
        self.isGap = isGap
        self.isMachineTranslation = isMachineTranslation
        self.vocalRole = vocalRole
        self.isRightAligned = isRightAligned ?? vocalRole.isRightAligned
        self.harmonies = harmonies
    }

    static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.time == rhs.time
            && lhs.text == rhs.text
            && lhs.words == rhs.words
            && lhs.translation == rhs.translation
            && lhs.transliteration == rhs.transliteration
            && lhs.confirmedEnd == rhs.confirmedEnd
            && lhs.translationLanguage == rhs.translationLanguage
            && lhs.isGap == rhs.isGap
            && lhs.isMachineTranslation == rhs.isMachineTranslation
            && lhs.vocalRole == rhs.vocalRole
            && lhs.isRightAligned == rhs.isRightAligned
            && lhs.harmonies == rhs.harmonies
    }

    var endTime: TimeInterval {
        words.last?.end ?? time
    }

    static func isParenthesizedVocal(_ text: some StringProtocol) -> Bool {
        !harmonyBracketOffsets(in: text).isEmpty && text.contains(where: \.isLetter)
    }

    static func trailingParenthesizedVocalStart(in text: String) -> String.Index? {
        text.indices.first { index in
            let character = text[index]
            return (character == "(" || character == "（") && isParenthesizedVocal(text[index...])
        }
    }

    fileprivate func hidingHarmonyBrackets() -> Self {
        guard vocalRole.isHarmony else { return self }
        let original = words.isEmpty ? text : words.map(\.text).joined()
        let brackets = Self.harmonyBracketOffsets(in: original)
        guard !brackets.isEmpty else { return self }

        var offset = 0
        func stripBrackets(from text: String) -> String {
            var result = ""
            for scalar in text.unicodeScalars {
                if !brackets.contains(offset) { result.unicodeScalars.append(scalar) }
                offset += 1
            }
            return result
        }

        let displayWords = words.compactMap { word -> LyricWord? in
            let text = stripBrackets(from: word.text)
            return text.isEmpty ? nil : LyricWord(text: text, start: word.start, end: word.end)
        }
        let displayText = words.isEmpty ? stripBrackets(from: text) : displayWords.map(\.text).joined()
        return Self(time: time, text: displayText, words: displayWords, translation: translation,
                    transliteration: transliteration, confirmedEnd: confirmedEnd,
                    translationLanguage: translationLanguage, isGap: isGap,
                    isMachineTranslation: isMachineTranslation, vocalRole: vocalRole,
                    isRightAligned: true, harmonies: harmonies)
    }

    private static func harmonyBracketOffsets(in text: some StringProtocol) -> Set<Int> {
        var expectedClosers: [Unicode.Scalar] = []
        var offsets = Set<Int>()
        var hasTrailingPunctuation = false
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            switch scalar {
            case "(", "（":
                if expectedClosers.isEmpty {
                    guard !hasTrailingPunctuation else { return [] }
                    offsets.insert(offset)
                }
                expectedClosers.append(scalar == "(" ? ")" : "）")
            case ")", "）":
                guard expectedClosers.popLast() == scalar else { return [] }
                if expectedClosers.isEmpty { offsets.insert(offset) }
            default:
                guard expectedClosers.isEmpty, !CharacterSet.whitespacesAndNewlines.contains(scalar),
                      scalar.properties.generalCategory != .format else { continue }
                guard !offsets.isEmpty, CharacterSet.punctuationCharacters.contains(scalar) else { return [] }
                hasTrailingPunctuation = true
            }
        }
        return expectedClosers.isEmpty ? offsets : []
    }
}

enum WordTimingQuality: String, Equatable, Sendable {
    /// No per-word data.
    case none
    /// Word or syllable timestamps supplied by the lyrics source.
    case exact
}

struct LyricsDocument: Equatable, Sendable {
    let lines: [LyricLine]
    let plainText: String?
    let source: String
    let isSynced: Bool
    let wordTiming: WordTimingQuality
    let artworkURL: URL?
    let sourceLanguage: String?

    /// nil means the source didn't declare a usable song language.
    var isDeclaredForeign: Bool? {
        Self.declaredLanguageCode(sourceLanguage).map { code in
            !["zh", "zho", "chi", "cmn", "yue", "wuu", "nan", "hak", "hsn", "gan", "lzh",
              "cdo", "cjy", "cpx", "czh", "czo", "mnp", "csp"].contains(code)
        }
    }

    static func declaredLanguageCode(_ tag: String?) -> String? {
        guard let code = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              (2...3).contains(code.count), code.utf8.allSatisfy({ (97...122).contains($0) }),
              !["und", "mul", "mis", "zxx"].contains(code) else { return nil }
        return String(code)
    }

    init(
        lines: [LyricLine],
        plainText: String?,
        source: String,
        isSynced: Bool,
        wordTiming: WordTimingQuality,
        artworkURL: URL? = nil,
        sourceLanguage: String? = nil
    ) {
        self.lines = lines
        self.plainText = plainText
        self.source = source
        self.isSynced = isSynced
        self.wordTiming = wordTiming
        self.artworkURL = artworkURL
        self.sourceLanguage = sourceLanguage
    }

    static let empty = LyricsDocument(
        lines: [],
        plainText: nil,
        source: "none",
        isSynced: false,
        wordTiming: .none,
        artworkURL: nil
    )

    func lineIndex(at position: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0
        var hi = lines.count - 1
        var answer: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }

    func line(at position: TimeInterval) -> LyricLine? {
        guard let index = lineIndex(at: position) else { return nil }
        return lines[index]
    }
}

enum AppStatus: Equatable, Sendable {
    case idle
    case musicNotRunning
    case stopped
    case loadingLyrics(TrackInfo)
    case showing(track: TrackInfo, lyrics: LyricsDocument, currentLine: String)
    case noLyrics(TrackInfo, cacheAccessDenied: Bool = false)
    case error(String)
}

extension LyricsDocument {
    /// Keep separate vocal rows local to the floating canvas. Translations and
    /// the menu-bar lyric still use the original paragraph sequence.
    var floatingLines: [LyricLine] {
        guard lines.contains(where: { $0.vocalRole.isHarmony || !$0.harmonies.isEmpty }) else { return lines }
        var rows = lines.map { $0.hidingHarmonyBrackets() }
        for line in lines {
            for harmony in line.harmonies {
                let row = LyricLine(time: harmony.time, text: harmony.text, words: harmony.words,
                                    vocalRole: line.vocalRole.harmonyRole)
                rows.append(row.hidingHarmonyBrackets())
            }
        }
        if rows.count != lines.count {
            rows.sort { first, second in
                if first.time != second.time { return first.time < second.time }
                return first.vocalRole.isHarmony && !second.vocalRole.isHarmony
            }
        }
        return rows
    }

    /// Builds presentation-only gap cues. Source timestamps remain untouched.
    func addingGaps(duration: TimeInterval, minimumGap: TimeInterval = 1.5) -> LyricsDocument {
        guard isSynced, !lines.isEmpty else { return self }
        var result: [LyricLine] = []
        var boundary: TimeInterval? = 0
        for line in lines {
            let onset = min(line.time, line.harmonies.lazy.map(\.time).min() ?? line.time)
            if let start = boundary, onset.isFinite, onset - start >= minimumGap {
                result.append(Self.gap(from: start, to: onset))
            }
            result.append(line)
            if let end = line.confirmedEnd, end.isFinite, end > line.time {
                let harmonyEnd = line.harmonies.lazy.flatMap(\.words).map(\.end).max() ?? end
                boundary = max(boundary ?? line.time, end, harmonyEnd)
            } else {
                boundary = nil
            }
        }
        if let end = boundary, duration.isFinite, duration - end >= minimumGap {
            result.append(Self.gap(from: end, to: duration))
        }
        return replacing(lines: result)
    }

    func replacing(lines: [LyricLine]) -> LyricsDocument {
        LyricsDocument(lines: lines, plainText: plainText, source: source, isSynced: isSynced,
                       wordTiming: wordTiming, artworkURL: artworkURL, sourceLanguage: sourceLanguage)
    }

    private static func gap(from start: TimeInterval, to end: TimeInterval) -> LyricLine {
        let step = (end - start) / 3
        let words = (0..<3).map { index in
            LyricWord(text: index < 2 ? "•\u{2009}" : "•", start: start + Double(index) * step,
                      end: start + Double(index + 1) * step)
        }
        return LyricLine(time: start, text: words.map(\.text).joined(), words: words, confirmedEnd: end, isGap: true)
    }
}

extension AppStatus {
    var track: TrackInfo? {
        switch self {
        case .loadingLyrics(let track), .noLyrics(let track, _), .showing(let track, _, _): return track
        default: return nil
        }
    }
}
