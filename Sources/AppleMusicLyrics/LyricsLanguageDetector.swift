import Foundation
import NaturalLanguage

struct TranslationGroup: Sendable {
    let language: String
    let lines: [Int: String]
}

enum LyricsLanguageDetector {
    static func groups(for document: LyricsDocument) -> [TranslationGroup] {
        let fullText = document.lines.map(\.text).joined(separator: "\n")
        let context = hypothesis(fullText)
        var groups: [String: [Int: String]] = [:]
        for (index, line) in document.lines.enumerated() {
            guard !line.isGap, !hasChineseTranslation(line),
                  let language = sourceLanguage(for: line.text, context: context) else { continue }
            groups[language, default: [:]][index] = line.text
        }
        return groups.keys.sorted().map { TranslationGroup(language: $0, lines: groups[$0] ?? [:]) }
    }

    static func hasChineseTranslation(_ line: LyricLine) -> Bool {
        guard let text = line.translation, !text.isEmpty else { return false }
        if let language = line.translationLanguage { return language.lowercased().hasPrefix("zh") }
        return hypothesis(text).map { isChinese($0.0) && $0.1 >= 0.7 } ?? false
    }

    private static func isChinese(_ language: NLLanguage) -> Bool {
        language == .simplifiedChinese || language == .traditionalChinese
    }

    private static func hypothesis(_ text: String) -> (NLLanguage, Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    private static func sourceLanguage(for text: String, context: (NLLanguage, Double)?) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return nil }
        let hasKana = text.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil
        let hasLatin = text.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
        let hanRuns = text.matches(of: try! Regex(#"\p{Han}+"#)).map { String($0.output[0].substring ?? "") }
        // Inspect Han runs with the recognizer; Han presence alone does not identify Chinese.
        let hasOtherLetters = letters.contains { scalar in
            String(scalar).range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) == nil
        }
        if hasOtherLetters || hasKana {
            for run in hanRuns where run.count >= 4 {
                if let (language, confidence) = hypothesis(run), isChinese(language), confidence >= 0.85 {
                    return nil
                }
            }
        }
        if hasOtherLetters, !hanRuns.isEmpty, !hasKana {
            // Mixed Han/foreign lines have ambiguous short runs, so conservatively skip them.
            return nil
        }
        if hasKana { return NLLanguage.japanese.rawValue }
        guard let (language, confidence) = hypothesis(text) else { return nil }
        if isChinese(language) {
            // Kanji-only Japanese lines need strong whole-song context to disambiguate.
            if !hasLatin, let (wholeLanguage, wholeConfidence) = context,
               wholeLanguage == .japanese, wholeConfidence >= 0.9, confidence < 0.85 {
                return wholeLanguage.rawValue
            }
            return nil
        }
        guard confidence >= 0.65 else { return nil }
        return language.rawValue
    }
}
