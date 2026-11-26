import Foundation

/// Time values in YRC are absolute milliseconds. LRC timestamps address whole lines.
enum NetEaseLyricParser {
    struct Payload: Decodable {
        struct Section: Decodable { let lyric: String? }
        let code: Int
        let nolyric: Bool?
        let uncollected: Bool?
        let lrc, yrc, tlyric, romalrc, ytlrc, yromalrc: Section?
    }

    private static let lrcStamp = try! NSRegularExpression(pattern: #"\[(\d{1,4}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let lrcOffset = try! NSRegularExpression(pattern: #"(?im)^\s*\[offset:\s*([+-]?\d{1,8})\s*\]"#)
    private static let yrcHeader = try! NSRegularExpression(pattern: #"^\[(\d{1,9}),(\d{1,8})\]"#)
    private static let yrcWord = try! NSRegularExpression(pattern: #"\((\d{1,9}),(\d{1,8}),\d+\)"#)

    static func document(_ payload: Payload, artworkURL: URL?, artists: [String] = []) -> LyricsDocument {
        guard payload.code == 200, payload.nolyric != true, payload.uncollected != true else {
            return empty(artworkURL: artworkURL)
        }
        let wordTimed = vocalLines(yrcLines(payload.yrc?.lyric), artists: artists)
        let hasWords = !wordTimed.isEmpty
        let base = (hasWords ? wordTimed : vocalLines(lrcLines(payload.lrc?.lyric), artists: artists)).sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            // Keep a simultaneous lead as the active line and the harmony beside it.
            return $0.vocalRole.isHarmony && !$1.vocalRole.isHarmony
        }
        if base.isEmpty {
            let plain = (payload.lrc?.lyric ?? "").components(separatedBy: .newlines).compactMap { raw -> String? in
                let text = decodeEntities(raw.trimmingCharacters(in: .whitespaces))
                guard !text.isEmpty, !text.hasPrefix("{"),
                      text.range(of: #"^\[(?:\d|[a-zA-Z]+:)"#, options: .regularExpression) == nil else { return nil }
                return text
            }.joined(separator: "\n")
            return LyricsDocument(lines: [], plainText: plain.isEmpty ? nil : plain, source: "NetEase Music",
                                  isSynced: false, wordTiming: .none, artworkURL: artworkURL)
        }
        let translations = aligned(primary: hasWords ? payload.ytlrc?.lyric : nil,
                                   fallback: payload.tlyric?.lyric, to: base)
        let readings = aligned(primary: hasWords ? payload.yromalrc?.lyric : nil,
                               fallback: payload.romalrc?.lyric, to: base)
        let lines = base.indices.map { index in
            let line = base[index]
            return LyricLine(time: line.time, text: line.text, words: line.words,
                             translation: translations[index], transliteration: readings[index],
                             confirmedEnd: line.confirmedEnd, vocalRole: line.vocalRole, harmonies: line.harmonies)
        }
        return LyricsDocument(lines: lines, plainText: nil, source: "NetEase Music",
                              isSynced: true, wordTiming: hasWords ? .exact : .none, artworkURL: artworkURL)
    }

    static func empty(artworkURL: URL?) -> LyricsDocument {
        LyricsDocument(lines: [], plainText: nil, source: "NetEase Music",
                       isSynced: false, wordTiming: .none, artworkURL: artworkURL)
    }

    private static func lrcLines(_ input: String?) -> [LyricLine] {
        guard let input, !input.isEmpty else { return [] }
        let original = input as NSString
        let match = lrcOffset.firstMatch(in: input, range: NSRange(location: 0, length: original.length))
        let milliseconds = match.flatMap { Double(original.substring(with: $0.range(at: 1))) } ?? 0
        var result: [LyricLine] = []
        for raw in input.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard line.first == "[" else { continue }
            // Read consecutive timestamps at the beginning. Brackets inside the actual lyric are text.
            var cursor = 0
            var timestamps: [Double] = []
            while cursor < ns.length,
                  let stamp = lrcStamp.firstMatch(in: line, options: .anchored,
                                                  range: NSRange(location: cursor, length: ns.length - cursor)) {
                let minutes = Double(ns.substring(with: stamp.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: stamp.range(at: 2))) ?? 0
                let fraction = stamp.range(at: 3)
                let decimal = fraction.location == NSNotFound ? 0 : Double("0." + ns.substring(with: fraction)) ?? 0
                if seconds < 60 { timestamps.append(max(0, minutes * 60 + seconds + decimal - milliseconds / 1000)) }
                cursor = NSMaxRange(stamp.range)
            }
            let text = decodeEntities(ns.substring(from: cursor).trimmingCharacters(in: .whitespaces))
            if !text.isEmpty { result.append(contentsOf: timestamps.map { LyricLine(time: $0, text: text) }) }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func yrcLines(_ input: String?) -> [LyricLine] {
        guard let input else { return [] }
        return input.components(separatedBy: .newlines).compactMap { raw -> LyricLine? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let entire = NSRange(location: 0, length: ns.length)
            guard let header = yrcHeader.firstMatch(in: line, range: entire),
                  let start = Double(ns.substring(with: header.range(at: 1))),
                  let duration = Double(ns.substring(with: header.range(at: 2))) else { return nil }
            let bodyStart = NSMaxRange(header.range)
            let tokens = yrcWord.matches(in: line, range: NSRange(location: bodyStart, length: ns.length - bodyStart))
            guard tokens.first?.range.location == bodyStart else { return nil }
            var words: [LyricWord] = []
            for (index, token) in tokens.enumerated() {
                let textStart = NSMaxRange(token.range)
                let textEnd = index + 1 < tokens.count ? tokens[index + 1].range.location : ns.length
                guard textEnd > textStart else { continue }
                let text = decodeEntities(ns.substring(with: NSRange(location: textStart, length: textEnd - textStart)))
                guard let onset = Double(ns.substring(with: token.range(at: 1))), onset >= start,
                      let length = Double(ns.substring(with: token.range(at: 2))) else { return nil }
                words.append(LyricWord(text: text, start: onset / 1000, end: (onset + length) / 1000))
            }
            guard let end = words.map(\.end).max() else { return nil }
            return LyricLine(time: start / 1000, text: words.map(\.text).joined(), words: words,
                             confirmedEnd: max((start + duration) / 1000, end))
        }.sorted { $0.time < $1.time }
    }

    private enum Singer: Hashable {
        case firstArtist, secondArtist, male, female, together

        var role: LyricVocalRole { self == .secondArtist || self == .female ? .partner : .lead }
    }

    private struct SingerLabel {
        let singer: Singer
        let body: String
        let prefixLength: Int
    }

    private static func vocalLines(_ lines: [LyricLine], artists: [String]) -> [LyricLine] {
        let names = artists.map(normalizedLabel).filter { !$0.isEmpty }
        var singers: [String: Singer] = [
            "男": .male, "男声": .male, "男生": .male,
            "女": .female, "女声": .female, "女生": .female,
            "合": .together, "合唱": .together, "齐唱": .together
        ]
        if names.count == 2, names[0] != names[1], singers[names[0]] == nil, singers[names[1]] == nil {
            singers[names[0]] = .firstArtist
            singers[names[1]] = .secondArtist
        }
        let labels = lines.map { singerLabel(in: $0.text, singers: singers) }
        let seen = Set(labels.compactMap { $0?.singer })
        // Require evidence for both soloists before treating prefixes as verse labels.
        let recognized: Set<Singer>
        if seen.contains(.firstArtist), seen.contains(.secondArtist) {
            recognized = [.firstArtist, .secondArtist, .together]
        } else if seen.contains(.male), seen.contains(.female) {
            recognized = [.male, .female, .together]
        } else {
            recognized = []
        }

        var role = LyricVocalRole.lead
        return zip(lines, labels).compactMap { line, label in
            let activeLabel = label.flatMap { recognized.contains($0.singer) ? $0 : nil }
            if label != nil { role = activeLabel?.singer.role ?? .lead }
            let text = activeLabel?.body ?? line.text
            guard !text.isEmpty else { return nil }
            let words = activeLabel.map { trimmedWords(line.words, prefixLength: $0.prefixLength) } ?? line.words
            let isHarmony = LyricLine.isParenthesizedVocal(text)
            if !isHarmony, let split = trailingVocal(in: words),
               ordered(split.lead), ordered(split.harmony), let first = split.harmony.first {
                return LyricLine(time: line.time, text: split.lead.map(\.text).joined(), words: split.lead,
                                 confirmedEnd: line.confirmedEnd, vocalRole: role,
                                 harmonies: [LyricHarmony(time: first.start, words: split.harmony)])
            }
            guard ordered(words) else { return nil }
            return LyricLine(time: line.time, text: text, words: words, confirmedEnd: line.confirmedEnd,
                             vocalRole: isHarmony ? role.harmonyRole : role)
        }
    }

    private static func singerLabel(in text: String, singers: [String: Singer]) -> SingerLabel? {
        guard let separator = text.firstIndex(where: { $0 == "：" || $0 == ":" }),
              let singer = singers[normalizedLabel(String(text[..<separator]))] else { return nil }
        let body = text[text.index(after: separator)...].drop(while: \.isWhitespace)
        return SingerLabel(singer: singer, body: String(body), prefixLength: body.startIndex.utf16Offset(in: text))
    }

    private static func normalizedLabel(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func trimmedWords(_ words: [LyricWord], prefixLength: Int) -> [LyricWord] {
        var remaining = prefixLength
        return words.compactMap { word in
            let text = word.text as NSString
            let dropped = min(remaining, text.length)
            remaining -= dropped
            guard dropped < text.length else { return nil }
            return LyricWord(text: text.substring(from: dropped), start: word.start, end: word.end)
        }
    }

    /// An independent marker keeps its timing. If both vocals share a marker,
    /// use the supplied interval for both parts.
    private static func trailingVocal(in words: [LyricWord]) -> (lead: [LyricWord], harmony: [LyricWord])? {
        let text = words.map(\.text).joined()
        guard let boundary = LyricLine.trailingParenthesizedVocalStart(in: text) else { return nil }
        let leadText = text[..<boundary]
        // Production credits commonly end with a parenthesized affiliation.
        guard leadText.contains(where: \.isLetter), !leadText.contains(":"), !leadText.contains("：") else { return nil }
        var remaining = boundary.utf16Offset(in: text)
        for (index, word) in words.enumerated() {
            let length = word.text.utf16.count
            if remaining >= length {
                remaining -= length
                continue
            }
            var lead = Array(words[..<index])
            var harmony = Array(words[index...])
            let split = String.Index(utf16Offset: remaining, in: word.text)
            let prefix = word.text[..<split]
            if !prefix.allSatisfy(\.isWhitespace) {
                lead.append(LyricWord(text: String(prefix), start: word.start, end: word.end))
                harmony[0] = LyricWord(text: String(word.text[split...]), start: word.start, end: word.end)
            }
            return (lead, harmony)
        }
        return nil
    }

    private static func ordered(_ words: [LyricWord]) -> Bool {
        zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Each secondary timestamp can annotate one original line. Missing translations must not shift subsequent rows.
    private static func aligned(primary: String?, fallback: String?, to base: [LyricLine]) -> [Int: String] {
        func match(_ input: String?) -> [Int: String] {
            var result: [Int: (distance: Double, text: String)] = [:]
            var index = 0
            for line in lrcLines(input) {
                while index + 1 < base.count,
                      abs(base[index + 1].time - line.time) <= abs(base[index].time - line.time) { index += 1 }
                let distance = abs(base[index].time - line.time)
                if distance <= 0.45, distance < (result[index]?.distance ?? .infinity) {
                    result[index] = (distance, line.text)
                }
            }
            return result.mapValues(\.text)
        }
        return match(primary).merging(match(fallback)) { preferred, _ in preferred }
    }
}
