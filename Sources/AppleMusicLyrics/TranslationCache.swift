import CryptoKit
import Foundation

actor TranslationCache {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleMusicLyricsV2/Translations", isDirectory: true)
    }

    nonisolated static func key(track: TrackInfo, document: LyricsDocument, source: String, target: String, quality: Bool) -> String {
        makeKey(prefix: ["v1", track.identityKey, track.album, source, target, String(quality)], document: document)
    }

    nonisolated static func onlineKey(track: TrackInfo, document: LyricsDocument, endpoint: URL, model: String,
                                      credentialID: UUID? = nil) -> String {
        var prefix = ["online-v1", track.identityKey, track.album, endpoint.absoluteString, model, "zh-Hans"]
        if let credentialID { prefix.append(credentialID.uuidString) }
        return makeKey(prefix: prefix, document: document)
    }

    private nonisolated static func makeKey(prefix: [String], document: LyricsDocument) -> String {
        let components = prefix + document.lines.map { "\($0.time)|\($0.text)" }
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func read(_ key: String) -> [Int: String]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode([Int: String].self, from: data)
    }

    func write(_ translations: [Int: String], key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(translations).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        } catch {
            DiagnosticLogger.shared.warning("Translation cache write failed: \(error.localizedDescription)")
        }
    }
}

extension LyricsDocument {
    func applyingMachineTranslations(_ translations: [Int: String]) -> LyricsDocument {
        replacing(lines: lines.enumerated().map { index, line in
            guard !line.hasPreferredOriginalTranslation, let translation = translations[index] else { return line }
            return LyricLine(time: line.time, text: line.text, words: line.words, translation: translation,
                             transliteration: line.transliteration, confirmedEnd: line.confirmedEnd,
                             translationLanguage: "zh-Hans", isGap: line.isGap, isMachineTranslation: true)
        })
    }
}
