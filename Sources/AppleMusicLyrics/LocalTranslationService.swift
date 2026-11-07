import AppKit
import SwiftUI
import Translation

@MainActor
final class LocalTranslationService {
    var onStatus: ((String) -> Void)?
    var onResult: ((LyricsDocument) -> Void)?
    private var engine: AnyObject?
    private(set) var hostView: NSView?

    init(cache: TranslationCache = TranslationCache()) {
        if #available(macOS 15, *) {
            let engine = TranslationEngine(cache: cache)
            self.engine = engine
            engine.onStatus = { [weak self] in self?.onStatus?($0) }
            engine.onResult = { [weak self] in self?.onResult?($0) }
            hostView = NSHostingView(rootView: TranslationHost(engine: engine))
        }
    }

    func start(document: LyricsDocument, track: TrackInfo) {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine {
            engine.start(document: document, track: track)
        } else { onStatus?("当前系统显示 Apple Music 缓存译文") }
    }

    func cancel() {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine { engine.cancel() }
    }

    func prepareResources() {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine { engine.prepareResources() }
    }
}

@available(macOS 15, *)
@MainActor
private final class TranslationEngine: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var onStatus: ((String) -> Void)?
    var onResult: ((LyricsDocument) -> Void)?
    private let cache: TranslationCache
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var current: (LyricsDocument, TrackInfo)?
    private var pending: PendingBatch?
    private(set) var pendingID = UUID()

    init(cache: TranslationCache) { self.cache = cache }

    private struct PendingBatch {
        let id: UUID
        let requests: [TranslationSession.Request]
        let continuation: CheckedContinuation<[TranslationSession.Response], Error>
    }

    func cancel() {
        current = nil
        task?.cancel()
        task = nil
        generation = UUID()
        finishPending(.failure(CancellationError()))
        configuration = nil
    }

    func start(document: LyricsDocument, track: TrackInfo, allowDownloads: Bool = false) {
        cancel()
        current = (document, track)
        guard AppPreferences.automaticTranslation else { onStatus?("自动翻译已关闭"); return }
        let token = generation
        let quality = AppPreferences.highQualityTranslation
        onStatus?("正在识别歌词语言…")
        task = Task { [weak self] in
            let groups = await Task.detached(priority: .utility) { LyricsLanguageDetector.groups(for: document) }.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            guard !groups.isEmpty else { self.onStatus?("已有译文，或歌词无需自动翻译"); return }
            var translated: [Int: String] = [:]
            var unavailable: [String] = []
            for group in groups {
                guard !Task.isCancelled, self.generation == token else { return }
                let key = TranslationCache.key(track: track, document: document, source: group.language,
                                               target: AppPreferences.translationTarget, quality: quality)
                if let cached = await self.cache.read(key) {
                    translated.merge(cached) { _, new in new }
                    continue
                }
                let source = Locale.Language(identifier: group.language)
                let target = Locale.Language(identifier: AppPreferences.translationTarget)
                let availability: LanguageAvailability
                if #available(macOS 26.4, *) {
                    availability = LanguageAvailability(preferredStrategy: quality ? .highFidelity : .lowLatency)
                } else { availability = LanguageAvailability() }
                let status = await availability.status(from: source, to: target)
                guard !Task.isCancelled, self.generation == token else { return }
                if status == .unsupported { unavailable.append("\(group.language) 暂不受支持"); continue }
                if status != .installed && !allowDownloads {
                    unavailable.append("\(group.language) 语言资源待准备，请在设置中下载")
                    continue
                }
                // Deduplicate repeated chorus lines within the same language batch.
                var representative: [String: Int] = [:]
                for index in group.lines.keys.sorted() {
                    if let text = group.lines[index], representative[text] == nil { representative[text] = index }
                }
                let requests = representative.sorted { $0.value < $1.value }.map {
                    TranslationSession.Request(sourceText: $0.key, clientIdentifier: String($0.value))
                }
                self.onStatus?("正在本地翻译 \(group.language)…")
                do {
                    let responses: [TranslationSession.Response]
                    if #available(macOS 26, *), status == .installed {
                        let session: TranslationSession
                        if #available(macOS 26.4, *) {
                            session = TranslationSession(installedSource: source, target: target, preferredStrategy: quality ? .highFidelity : .lowLatency)
                        } else { session = TranslationSession(installedSource: source, target: target) }
                        responses = try await session.translations(from: requests)
                    } else {
                        responses = try await self.translateWithHost(requests: requests, source: source, target: target, quality: quality)
                    }
                    guard !Task.isCancelled, self.generation == token else { return }
                    var byText: [String: String] = [:]
                    for response in responses {
                        guard let id = response.clientIdentifier.flatMap(Int.init), let original = group.lines[id],
                              !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        byText[original] = response.targetText
                    }
                    var result: [Int: String] = [:]
                    for (index, text) in group.lines { result[index] = byText[text] }
                    if result.count == group.lines.count { await self.cache.write(result, key: key) }
                    translated.merge(result) { _, new in new }
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    unavailable.append("\(group.language) 翻译暂不可用")
                    DiagnosticLogger.shared.warning("Local translation failed: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            let lines = document.lines.enumerated().map { index, line -> LyricLine in
                guard let translation = translated[index] else { return line }
                return LyricLine(time: line.time, text: line.text, words: line.words, translation: translation,
                                 transliteration: line.transliteration, confirmedEnd: line.confirmedEnd,
                                 translationLanguage: "zh-Hans", isGap: line.isGap, isMachineTranslation: true)
            }
            self.onResult?(document.replacing(lines: lines))
            self.onStatus?(unavailable.isEmpty ? "本地译文已就绪" : unavailable.joined(separator: "\n"))
        }
    }

    func prepareResources() {
        guard let (document, track) = current else { onStatus?("请先播放一首有外语歌词的歌曲"); return }
        start(document: document, track: track, allowDownloads: true)
    }

    private func translateWithHost(requests: [TranslationSession.Request], source: Locale.Language,
                                   target: Locale.Language, quality: Bool) async throws -> [TranslationSession.Response] {
        try await withCheckedThrowingContinuation { continuation in
            pendingID = UUID()
            pending = PendingBatch(id: pendingID, requests: requests, continuation: continuation)
            var config: TranslationSession.Configuration
            if #available(macOS 26.4, *) {
                config = .init(source: source, target: target, preferredStrategy: quality ? .highFidelity : .lowLatency)
            } else { config = .init(source: source, target: target) }
            config.invalidate()
            configuration = config
        }
    }

    func run(session: TranslationSession, id: UUID) async {
        guard let work = pending, work.id == id else { return }
        do {
            try await session.prepareTranslation()
            let response = try await session.translations(from: work.requests)
            guard pending?.id == work.id else { return }
            finishPending(.success(response))
        } catch {
            guard pending?.id == work.id else { return }
            finishPending(.failure(error))
        }
    }

    private func finishPending(_ result: Result<[TranslationSession.Response], Error>) {
        let work = pending
        pending = nil
        work?.continuation.resume(with: result)
    }
}

@available(macOS 15, *)
private struct TranslationHost: View {
    @ObservedObject var engine: TranslationEngine
    var body: some View {
        let id = engine.pendingID
        Color.clear.translationTask(engine.configuration) { session in
            await engine.run(session: session, id: id)
        }
    }
}
