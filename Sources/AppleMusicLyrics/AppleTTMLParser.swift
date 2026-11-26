import Foundation

struct ParsedAppleTTML: Equatable {
    let lines: [LyricLine]
    let wordTiming: WordTimingQuality
}

enum AppleTTMLParser {
    static func parse(_ content: String) throws -> ParsedAppleTTML {
        guard let data = content.data(using: .utf8) else {
            throw ParseError.invalidEncoding
        }

        let delegate = TTMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? ParseError.invalidDocument
        }
        return ParsedAppleTTML(
            lines: delegate.lines.sorted { $0.time < $1.time },
            wordTiming: delegate.hasTimedSpan ? .exact : .none
        )
    }

    private final class TTMLDelegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        var hasTimedSpan = false

        private var depth = 0
        private var bodyDepth: Int?
        private var metadataDepth: Int?
        private var translationBlock: (depth: Int, language: String?)?
        private var translationEntry: (depth: Int, key: String, text: String)?
        private var translations: [String: (text: String, language: String?)] = [:]
        private static let metadataNamespace = "http://www.w3.org/ns/ttml#metadata"
        private var namespaceBindings: [String: [String]] = [:]
        private var singerIDs: [String] = []
        private var groupIDs: Set<String> = []
        private var vocals: [LineBuilder] = []

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            namespaceBindings[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = namespaceBindings[prefix]?.popLast()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            let name = localName(elementName, qualifiedName: qName)
            if name == "body" {
                bodyDepth = depth
                return
            }
            guard bodyDepth != nil else {
                if name == "agent", namespaceURI == Self.metadataNamespace, let id = attributeDict["xml:id"] {
                    if attributeDict["type"] == "group" {
                        groupIDs.insert(id)
                    } else if !singerIDs.contains(id) {
                        singerIDs.append(id)
                    }
                } else if name == "iTunesMetadata" {
                    metadataDepth = depth
                } else if metadataDepth != nil, name == "translation",
                          attributeDict["type"] == nil || attributeDict["type"] == "subtitle" {
                    translationBlock = (depth, attributeDict["xml:lang"])
                } else if translationBlock != nil, name == "text", let key = attributeDict["for"] {
                    translationEntry = (depth, key, "")
                }
                return
            }

            if name == "p" {
                let singer = singerRole(for: attributeDict)
                vocals = [LineBuilder(
                    depth: depth,
                    start: time(attributeDict["begin"]),
                    end: time(attributeDict["end"]),
                    key: attributeDict["itunes:key"] ?? attributeDict.first { $0.key.hasSuffix(":key") }?.value,
                    role: isHarmony(attributeDict) ? singer.harmonyRole : singer
                )]
            } else if name == "span", !vocals.isEmpty {
                if vocals.count == 1, isHarmony(attributeDict) {
                    let role = vocals[0].role.harmonyRole
                    vocals.append(LineBuilder(depth: depth, start: time(attributeDict["begin"]),
                                              end: time(attributeDict["end"]), key: nil, role: role))
                } else if let start = time(attributeDict["begin"]) {
                    vocals[vocals.count - 1].spans.append(
                        SpanBuilder(depth: depth, text: "", start: start, end: time(attributeDict["end"]))
                    )
                }
            } else if name == "br" {
                appendText("\n")
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName, qualifiedName: qName)

            if let entry = translationEntry, entry.depth == depth {
                let text = normalizedWhitespace(entry.text).trimmingCharacters(in: .whitespacesAndNewlines)
                let language = translationBlock?.language
                let previous = translations[entry.key]
                if !text.isEmpty, previous == nil || (isChinese(language) && !isChinese(previous?.language)) {
                    translations[entry.key] = (text, language)
                }
                translationEntry = nil
            } else if translationBlock?.depth == depth {
                translationBlock = nil
            } else if metadataDepth == depth {
                metadataDepth = nil
            } else if name == "span", !vocals.isEmpty {
                let index = vocals.count - 1
                if index > 0, vocals[index].depth == depth, let harmony = vocals.popLast() {
                    let words = finishedWords(for: harmony, fallbackStart: vocals[0].start, fallbackEnd: vocals[0].end)
                    if let first = words.first {
                        vocals[0].harmonies.append(LyricHarmony(time: harmony.start ?? first.start, words: lyricWords(words)))
                    }
                } else if vocals[index].spans.last?.depth == depth, let span = vocals[index].spans.popLast() {
                    flush(span: span, into: index)
                }
            } else if name == "p", let line = vocals.first {
                finish(line: line)
                vocals.removeAll(keepingCapacity: true)
            } else if name == "body", bodyDepth == depth {
                bodyDepth = nil
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if translationEntry != nil {
                translationEntry?.text += string
                return
            }
            appendText(string)
        }

        private func appendText(_ text: String) {
            guard !vocals.isEmpty else { return }
            let index = vocals.count - 1
            if let span = vocals[index].spans.indices.last {
                vocals[index].spans[span].text += text
            } else {
                vocals[index].pendingText += text
            }
        }

        private func flush(span: SpanBuilder, into index: Int) {
            let rawText = normalizedWhitespace(span.text)
            guard !rawText.isEmpty else { return }

            let text = normalizedWhitespace(vocals[index].pendingText) + rawText
            let end = vocals[index].end ?? vocals.first?.end
            vocals[index].pendingText = ""
            vocals[index].words.append(
                MutableWord(
                    text: text,
                    start: span.start,
                    end: max(span.end ?? end ?? span.start + 0.1, span.start + 0.01),
                    explicitEnd: span.end
                )
            )
            hasTimedSpan = true
        }

        private func finishedWords(for line: LineBuilder, fallbackStart: TimeInterval? = nil,
                                   fallbackEnd: TimeInterval? = nil) -> [MutableWord] {
            var words = line.words
            if words.isEmpty {
                let text = normalizedWhitespace(line.pendingText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return [] }
                let start = line.start ?? fallbackStart ?? 0
                words = [MutableWord(text: text, start: start,
                                     end: max(line.end ?? fallbackEnd ?? start + 0.2, start + 0.01))]
            } else if !line.pendingText.isEmpty {
                words[words.count - 1].text += normalizedWhitespace(line.pendingText)
            }
            trimEdges(of: &words)
            return words
        }

        private func finish(line: LineBuilder) {
            var words = finishedWords(for: line)
            var role = line.role
            var harmonies = line.harmonies
            let translation = line.key.flatMap { translations[$0] }
            guard let first = words.first else {
                // Some paragraphs consist entirely of an explicit background span.
                for (index, harmony) in harmonies.enumerated() {
                    lines.append(LyricLine(time: harmony.time, text: harmony.text, words: harmony.words,
                                           translation: index == 0 ? translation?.text : nil,
                                           confirmedEnd: index == harmonies.count - 1 ? line.end : nil,
                                           translationLanguage: index == 0 ? translation?.language : nil,
                                           vocalRole: role.isHarmony ? role : role.harmonyRole))
                }
                return
            }
            let confirmedEnd = line.end ?? (words.allSatisfy { $0.explicitEnd != nil }
                ? words.compactMap(\.explicitEnd).max() : nil)
            if harmonies.isEmpty, !role.isHarmony {
                let text = words.map(\.text).joined()
                if LyricLine.isParenthesizedVocal(text) {
                    role = role.harmonyRole
                } else if let split = trailingHarmony(in: words, text: text), let start = split.harmony.first?.start {
                    words = split.lead
                    harmonies = [LyricHarmony(time: start, words: lyricWords(split.harmony))]
                }
            }
            lines.append(LyricLine(time: line.start ?? first.start, text: words.map(\.text).joined(),
                                   words: lyricWords(words), translation: translation?.text,
                                   confirmedEnd: confirmedEnd, translationLanguage: translation?.language,
                                   vocalRole: role, harmonies: harmonies))
        }

        private func lyricWords(_ words: [MutableWord]) -> [LyricWord] {
            words.map { LyricWord(text: $0.text, start: $0.start, end: $0.end) }
        }

        private func metadataAttribute(_ name: String, in attributes: [String: String]) -> String? {
            for (prefix, bindings) in namespaceBindings where bindings.last == Self.metadataNamespace {
                if let value = attributes["\(prefix):\(name)"] { return value }
            }
            return nil
        }

        private func isHarmony(_ attributes: [String: String]) -> Bool {
            metadataAttribute("role", in: attributes)?.split(whereSeparator: \.isWhitespace).contains("x-bg") == true
        }

        private func singerRole(for attributes: [String: String]) -> LyricVocalRole {
            guard let references = metadataAttribute("agent", in: attributes)?.split(whereSeparator: \.isWhitespace),
                  references.count == 1 else { return .lead }
            let id = String(references[0])
            guard !groupIDs.contains(id) else { return .lead }
            if id == "v1" { return .lead }
            if id == "v2" { return .partner }
            if !singerIDs.contains(id) { singerIDs.append(id) }
            return (singerIDs.firstIndex(of: id) ?? 0).isMultiple(of: 2) ? .lead : .partner
        }

        private func localName(_ elementName: String, qualifiedName: String?) -> String {
            let value = qualifiedName ?? elementName
            return value.split(separator: ":").last.map(String.init) ?? value
        }

        private func isChinese(_ language: String?) -> Bool {
            language?.lowercased().hasPrefix("zh") == true
        }
    }

    private static func time(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("ms"), let milliseconds = Double(value.dropLast(2)) {
            return milliseconds / 1000
        }
        if value.hasSuffix("s"), let seconds = Double(value.dropLast()) {
            return seconds
        }

        let rawParts = value.split(separator: ":")
        guard !rawParts.isEmpty, rawParts.count <= 3 else { return nil }
        let parts = rawParts.compactMap { Double($0) }
        guard parts.count == rawParts.count else { return nil }
        return parts.reversed().enumerated().reduce(0) { result, item in
            result + item.element * pow(60, Double(item.offset))
        }
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        var result = ""
        var previousWasWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !previousWasWhitespace { result.append(" ") }
                previousWasWhitespace = true
            } else {
                result.append(character)
                previousWasWhitespace = false
            }
        }
        return result
    }

    private static func trailingHarmony(in words: [MutableWord], text: String) -> (lead: [MutableWord], harmony: [MutableWord])? {
        guard let boundary = LyricLine.trailingParenthesizedVocalStart(in: text),
              text[..<boundary].contains(where: \.isLetter) else { return nil }
        let offset = boundary.utf16Offset(in: text)
        var lead: [MutableWord] = []
        var harmony: [MutableWord] = []
        var remaining = offset
        for word in words {
            let length = word.text.utf16.count
            if remaining <= 0 {
                harmony.append(word)
            } else if remaining >= length {
                lead.append(word)
            } else {
                let boundary = String.Index(utf16Offset: remaining, in: word.text)
                let prefix = word.text[..<boundary]
                let suffix = word.text[boundary...]
                let sungLength = prefix.trimmingCharacters(in: .whitespacesAndNewlines).count
                let fraction = Double(sungLength) / Double(sungLength + suffix.count)
                let time = word.start + (word.end - word.start) * fraction
                lead.append(MutableWord(text: String(prefix), start: word.start, end: time))
                harmony.append(MutableWord(text: String(suffix), start: time, end: word.end, explicitEnd: word.explicitEnd))
            }
            remaining -= length
        }
        trimEdges(of: &lead)
        trimEdges(of: &harmony)
        return (lead, harmony)
    }

    private static func trimEdges(of words: inout [MutableWord]) {
        guard !words.isEmpty else { return }
        if let firstNonSpace = words[0].text.firstIndex(where: { !$0.isWhitespace }) {
            if firstNonSpace > words[0].text.startIndex {
                words[0].text = String(words[0].text[firstNonSpace...])
            }
        } else {
            words[0].text = ""
        }
        let lastIndex = words.count - 1
        if let lastNonSpace = words[lastIndex].text.lastIndex(where: { !$0.isWhitespace }) {
            let next = words[lastIndex].text.index(after: lastNonSpace)
            if next < words[lastIndex].text.endIndex {
                words[lastIndex].text = String(words[lastIndex].text[..<next])
            }
        } else {
            words[lastIndex].text = ""
        }
        words.removeAll { $0.text.isEmpty }
    }

    private struct LineBuilder {
        let depth: Int
        let start: TimeInterval?
        let end: TimeInterval?
        let key: String?
        let role: LyricVocalRole
        var pendingText = ""
        var words: [MutableWord] = []
        var spans: [SpanBuilder] = []
        var harmonies: [LyricHarmony] = []
    }

    private struct SpanBuilder {
        let depth: Int
        var text: String
        let start: TimeInterval
        let end: TimeInterval?
    }

    private struct MutableWord {
        var text: String
        let start: TimeInterval
        let end: TimeInterval
        var explicitEnd: TimeInterval? = nil
    }

    enum ParseError: Error {
        case invalidEncoding
        case invalidDocument
    }
}
