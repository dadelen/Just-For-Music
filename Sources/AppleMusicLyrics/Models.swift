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
    let state: PlayerState

    var identityKey: String {
        "\(artist.lowercased())|\(title.lowercased())|\(Int(duration.rounded()))"
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

struct LyricLine: Equatable, Sendable, Identifiable {
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

    var id: String { "\(time)-\(text.hashValue)" }

    init(
        time: TimeInterval,
        text: String,
        words: [LyricWord] = [],
        translation: String? = nil,
        transliteration: String? = nil,
        confirmedEnd: TimeInterval? = nil,
        translationLanguage: String? = nil,
        isGap: Bool = false,
        isMachineTranslation: Bool = false
    ) {
        self.time = time
        self.text = text
        self.words = words
        self.translation = translation
        self.transliteration = transliteration
        self.confirmedEnd = confirmedEnd
        self.translationLanguage = translationLanguage
        self.isGap = isGap
        self.isMachineTranslation = isMachineTranslation
    }

    var endTime: TimeInterval {
        words.last?.end ?? time
    }
}

enum WordTimingQuality: String, Equatable, Sendable, Codable {
    /// No per-word data.
    case none
    /// Synthesized from line LRC timestamps.
    case estimated
    /// Exact timings from Apple Music word-timed TTML.
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

    var hasKaraoke: Bool {
        wordTiming != .none && lines.contains { !$0.words.isEmpty }
    }

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
    case noLyrics(TrackInfo)
    case error(String)
}

extension LyricsDocument {
    /// Builds presentation-only gap cues. Source timestamps remain untouched.
    func addingGaps(duration: TimeInterval, minimumGap: TimeInterval = 1.5) -> LyricsDocument {
        guard isSynced, !lines.isEmpty else { return self }
        var result: [LyricLine] = []
        var boundary: TimeInterval? = 0
        for line in lines {
            if let start = boundary, line.time.isFinite, line.time - start >= minimumGap {
                result.append(Self.gap(from: start, to: line.time))
            }
            result.append(line)
            if let end = line.confirmedEnd, end.isFinite, end > line.time {
                boundary = max(boundary ?? line.time, end)
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
            LyricWord(text: "•", start: start + Double(index) * step,
                      end: start + Double(index + 1) * step)
        }
        return LyricLine(time: start, text: "•••", words: words, confirmedEnd: end, isGap: true)
    }
}

extension AppStatus {
    var track: TrackInfo? {
        switch self {
        case .loadingLyrics(let track), .noLyrics(let track), .showing(let track, _, _): return track
        default: return nil
        }
    }
}
