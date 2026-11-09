import Foundation
import NaturalLanguage

struct TranslationGroup: Sendable {
    let language: String
    let lines: [Int: String]
}

enum LyricsLanguageDetector {
    private static let hanRuns = try! NSRegularExpression(pattern: #"\p{Han}+"#)
    private static let kana = try! NSRegularExpression(pattern: #"[\p{Hiragana}\p{Katakana}]"#)
    private static let latin = try! NSRegularExpression(pattern: #"\p{Latin}"#)
    private static let nonHanLetters = try! NSRegularExpression(pattern: #"(?=\p{L})[^\p{Han}]"#)
    private static let nonHanKanaLetters = try! NSRegularExpression(pattern: #"(?=\p{L})[^\p{Han}\p{Hiragana}\p{Katakana}]"#)

    enum SongLanguage: Equatable, Sendable {
        case chinese, foreign, uncertain
    }

    static func songLanguage(for document: LyricsDocument) -> SongLanguage {
        if let foreign = document.isDeclaredForeign { return foreign ? .foreign : .chinese }

        var seen: Set<String> = []
        let lines = document.lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isGap, text.rangeOfCharacter(from: .letters) != nil, seen.insert(text).inserted else { return nil }
            return text
        }
        guard !lines.isEmpty else { return .uncertain }
        let sample = lines.joined(separator: "\n")
        let containsHan = matches(hanRuns, in: sample)
        let containsKana = matches(kana, in: sample)
        let hasNonHanLetters = matches(nonHanLetters, in: sample)
        // Short strings made entirely of Han characters may be Chinese or Japanese kanji.
        if containsHan, !hasNonHanLetters,
           sample.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count < 24 {
            return .uncertain
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let ranked = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        guard let first = ranked.first else { return .uncertain }
        let confidenceMargin = first.value - (ranked.dropFirst().first?.value ?? 0)
        guard first.value >= 0.8, confidenceMargin >= 0.25 else { return .uncertain }
        if isChinese(first.key) { return .chinese }
        if first.key == .japanese, !containsKana { return .uncertain }
        if containsHan {
            // A long foreign line can dominate the aggregate score despite several Chinese or mixed lines.
            var ambiguousHanCount = 0
            var foreignCount = 0
            for line in lines {
                let hasHan = matches(hanRuns, in: line)
                let hasKana = matches(kana, in: line)
                if hasHan, !hasKana {
                    ambiguousHanCount += 1
                } else if let (language, confidence) = hypothesis(line, using: recognizer), !isChinese(language), confidence >= 0.65 {
                    foreignCount += 1
                }
            }
            if ambiguousHanCount >= foreignCount { return .uncertain }
        }
        return .foreign
    }

    static func groups(for document: LyricsDocument, restrictingTo lineIDs: Set<Int>? = nil,
                       songLanguage: SongLanguage? = nil) -> [TranslationGroup] {
        guard (songLanguage ?? Self.songLanguage(for: document)) == .foreign else { return [] }
        let textLines = document.lines.filter { !$0.isGap && $0.text.rangeOfCharacter(from: .letters) != nil }.map(\.text)
        let recognizer = NLLanguageRecognizer()
        let context = hypothesis(textLines.joined(separator: "\n"), using: recognizer)
        let fallbackScript = context.flatMap(contextScript)
        var predictions: [String: (NLLanguage, Double)?] = [:]
        var groups: [String: [Int: String]] = [:]
        for (index, line) in document.lines.enumerated() {
            guard lineIDs?.contains(index) != false, !line.isGap, !line.hasPreferredOriginalTranslation,
                  line.text.rangeOfCharacter(from: .letters) != nil else { continue }
            let prediction = predictions[line.text] ?? hypothesis(line.text, using: recognizer)
            predictions.updateValue(prediction, forKey: line.text)
            guard let language = sourceLanguage(for: line.text, prediction: prediction, context: context,
                                                fallbackScript: fallbackScript, recognizer: recognizer) else { continue }
            groups[language, default: [:]][index] = line.text
        }
        return groups.keys.sorted().map { TranslationGroup(language: $0, lines: groups[$0] ?? [:]) }
    }

    private static func isChinese(_ language: NLLanguage) -> Bool {
        language == .simplifiedChinese || language == .traditionalChinese
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hypothesis(_ text: String, using recognizer: NLLanguageRecognizer) -> (NLLanguage, Double)? {
        recognizer.reset()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    private static func sourceLanguage(for text: String, prediction: (NLLanguage, Double)?,
                                       context: (NLLanguage, Double)?, fallbackScript: NSRegularExpression?,
                                       recognizer: NLLanguageRecognizer) -> String? {
        let hasKana = matches(kana, in: text)
        let hasLatin = matches(latin, in: text)
        let hanRanges = hanRuns.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Inspect Han runs with the recognizer; Han presence alone does not identify Chinese.
        let hasOtherLetters = matches(nonHanKanaLetters, in: text)
        if (hasOtherLetters || hasKana), !hanRanges.isEmpty {
            let utf16Text = text as NSString
            for match in hanRanges {
                let run = utf16Text.substring(with: match.range)
                guard run.count >= 4 else { continue }
                if let (language, confidence) = hypothesis(run, using: recognizer),
                   isChinese(language), confidence >= 0.85 {
                    return nil
                }
            }
        }
        if hasOtherLetters, !hanRanges.isEmpty, !hasKana {
            // Mixed Han/foreign lines have ambiguous short runs, so conservatively skip them.
            return nil
        }
        if hasKana { return NLLanguage.japanese.rawValue }
        if let (language, confidence) = prediction {
            if isChinese(language) {
                // Kanji-only Japanese lines need strong whole-song context to disambiguate.
                if !hasLatin, let (wholeLanguage, wholeConfidence) = context,
                   wholeLanguage == .japanese, wholeConfidence >= 0.9, confidence < 0.85 {
                    return wholeLanguage.rawValue
                }
                return nil
            }
            if confidence >= 0.65 { return language.rawValue }
        }
        // Short interjections often have no reliable per-line language prediction.
        guard hanRanges.isEmpty, let (language, _) = context,
              let fallbackScript, !matches(fallbackScript, in: text) else { return nil }
        return language.rawValue
    }

    private static func contextScript(_ context: (NLLanguage, Double)) -> NSRegularExpression? {
        let (language, confidence) = context
        guard confidence >= 0.8, !isChinese(language),
              let script = Locale.Language(identifier: language.rawValue).script?.identifier else { return nil }
        let letterScript = script == "Kore" ? "Hangul" : script
        return try? NSRegularExpression(pattern: "(?=\\p{L})[^\\p{\(letterScript)}]")
    }
}
