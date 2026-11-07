import CryptoKit
import Foundation

actor TranslationCache {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleMusicLyricsV2/Translations", isDirectory: true)
    }

    nonisolated static func key(track: TrackInfo, document: LyricsDocument, source: String, target: String, quality: Bool) -> String {
        let components = ["v1", track.identityKey, track.album, source, target, String(quality)]
            + document.lines.map { "\($0.time)|\($0.text)" }
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
