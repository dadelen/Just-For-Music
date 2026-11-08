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

    @available(macOS 15, *)
    static func installedSourceLanguageNames() async -> [String] {
        let availability = translationLanguageAvailability()
        let target = Locale.Language(identifier: AppPreferences.translationTarget)
        let locale = Locale(identifier: AppPreferences.translationTarget)
        var names: Set<String> = []
        for source in await availability.supportedLanguages {
            guard !Task.isCancelled else { return [] }
            guard await availability.status(from: source, to: target) == .installed else { continue }
            let identifier = source.minimalIdentifier
            names.insert(locale.localizedString(forIdentifier: identifier) ?? identifier)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func start(document: LyricsDocument, track: TrackInfo) {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine {
            engine.start(document: document, track: track)
        } else { onStatus?("当前系统显示 Apple Music 缓存译文") }
    }

    func startFallback(document: LyricsDocument, track: TrackInfo, pendingLineIDs: Set<Int>, onlineTranslations: [Int: String]) {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine {
            engine.start(document: document, track: track, pendingLineIDs: pendingLineIDs, onlineTranslations: onlineTranslations)
        } else {
            onStatus?("本地补译需要 macOS 15 或更新版本。")
        }
    }

    func cancel() {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine { engine.cancel() }
    }

    func suspend() {
        if #available(macOS 15, *), let engine = engine as? TranslationEngine { engine.suspend() }
    }
}

@available(macOS 15, *)
private func translationLanguageAvailability() -> LanguageAvailability {
    if #available(macOS 26.4, *) {
        return LanguageAvailability(preferredStrategy: .lowLatency)
    }
    return LanguageAvailability()
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
    private var current: Work?
    private var activeSession: TranslationSession?
    private var pending: PendingBatch?
    private(set) var pendingID = UUID()

    init(cache: TranslationCache) { self.cache = cache }

    private struct Work: Equatable {
        let document: LyricsDocument
        let trackKey: String
        let pendingLineIDs: Set<Int>?
        let onlineTranslations: [Int: String]?
    }

    private struct PendingBatch {
        let id: UUID
        let requests: [TranslationSession.Request]
        let continuation: CheckedContinuation<[String: String], Error>
    }

    private struct MissingLanguagePack: Error {}

    func cancel() {
        current = nil
        task?.cancel()
        task = nil
        generation = UUID()
        if #available(macOS 26, *) { activeSession?.cancel() }
        activeSession = nil
        finishPending(.failure(CancellationError()))
        configuration = nil
    }

    func suspend() {
        guard task != nil else { return }
        cancel()
        onStatus?("显示桌面译文后继续翻译")
    }

    func start(document: LyricsDocument, track: TrackInfo,
               pendingLineIDs: Set<Int>? = nil, onlineTranslations: [Int: String]? = nil) {
        let work = Work(document: document, trackKey: track.identityKey,
                        pendingLineIDs: pendingLineIDs, onlineTranslations: onlineTranslations)
        guard work != current else { return }
        cancel()
        guard AppPreferences.automaticTranslation else {
            onStatus?("自动翻译已关闭")
            return
        }
        current = work
        let token = generation
        onStatus?(pendingLineIDs == nil ? "正在识别歌词语言…" : "正在准备本地补译…")
        task = Task { [weak self] in
            defer {
                if let self, self.generation == token {
                    self.task = nil
                    if self.configuration != nil { self.configuration = nil }
                }
            }
            guard !Task.isCancelled else { return }
            let (language, groups) = await Task.detached(priority: .utility) {
                let language = LyricsLanguageDetector.songLanguage(for: document)
                return (language, LyricsLanguageDetector.groups(for: document, restrictingTo: pendingLineIDs,
                                                                 songLanguage: language))
            }.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            switch language {
            case .chinese: self.onStatus?("当前歌曲以中文为主，已保留原文。"); return
            case .uncertain: self.onStatus?("本机无法确认当前歌曲以外语为主，已保留原文。"); return
            case .foreign: break
            }
            guard !groups.isEmpty else { self.onStatus?("已有译文，或歌词无需自动翻译"); return }
            var translated = onlineTranslations ?? [:]
            var unavailable: [String] = []
            for group in groups {
                guard !Task.isCancelled, self.generation == token else { return }
                let key = TranslationCache.key(track: track, document: document, source: group.language,
                                               target: AppPreferences.translationTarget, quality: false)
                var cached = await self.cache.read(key) ?? [:]
                if group.lines.keys.contains(where: { cached[$0]?.isEmpty != false }) {
                    let highQualityKey = TranslationCache.key(track: track, document: document, source: group.language,
                                                              target: AppPreferences.translationTarget, quality: true)
                    if let highQualityCache = await self.cache.read(highQualityKey) {
                        cached.merge(highQualityCache) { existing, _ in existing }
                    }
                }
                guard !Task.isCancelled, self.generation == token else { return }
                // Reuse cached translations by text, including repeated chorus lines.
                var byText: [String: String] = [:]
                var representative: [String: Int] = [:]
                for index in group.lines.keys.sorted() {
                    guard let text = group.lines[index] else { continue }
                    if let translation = cached[index], !translation.isEmpty { byText[text] = translation }
                    if representative[text] == nil { representative[text] = index }
                }
                let requests = representative.sorted { $0.value < $1.value }.compactMap { text, index in
                    byText[text] == nil ? TranslationSession.Request(sourceText: text, clientIdentifier: String(index)) : nil
                }
                for (index, text) in group.lines { translated[index] = byText[text] }
                guard !requests.isEmpty else { continue }
                let source = Locale.Language(identifier: group.language)
                let target = Locale.Language(identifier: AppPreferences.translationTarget)
                let availability = translationLanguageAvailability()
                let status = await availability.status(from: source, to: target)
                guard !Task.isCancelled, self.generation == token else { return }
                let languageName = Locale(identifier: "zh_Hans").localizedString(forIdentifier: group.language) ?? group.language
                let missingPack = "缺少\(languageName)语言包，请在系统设置的「语言与地区」中下载。"
                guard status == .installed else {
                    unavailable.append(status == .supported ? missingPack : "\(languageName)暂不受支持")
                    continue
                }
                do {
                    self.onStatus?("正在本地翻译\(languageName)歌词…")
                    let newTranslations: [String: String]
                    if #available(macOS 26, *) {
                        let session: TranslationSession
                        if #available(macOS 26.4, *) {
                            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                        } else { session = TranslationSession(installedSource: source, target: target) }
                        self.activeSession = session
                        defer { if self.activeSession === session { self.activeSession = nil } }
                        newTranslations = try await self.translate(requests, using: session)
                    } else {
                        newTranslations = try await self.translateWithHost(requests: requests, source: source, target: target)
                    }
                    guard !Task.isCancelled, self.generation == token else { return }
                    byText.merge(newTranslations) { _, new in new }
                    var result: [Int: String] = [:]
                    for (index, text) in group.lines { result[index] = byText[text] }
                    if !result.isEmpty {
                        cached.merge(result) { _, new in new }
                        await self.cache.write(cached, key: key)
                    }
                    translated.merge(result) { _, new in new }
                    let remaining = group.lines.count - result.count
                    if remaining > 0 { unavailable.append("\(languageName)还有 \(remaining) 句未译出，下次播放时重试") }
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    let latestStatus = await availability.status(from: source, to: target)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if error is MissingLanguagePack || latestStatus == .supported {
                        unavailable.append(missingPack)
                        continue
                    }
                    unavailable.append("\(languageName)翻译暂不可用")
                    DiagnosticLogger.shared.warning("Local translation failed: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.onResult?(document.applyingMachineTranslations(translated))
            let success = onlineTranslations == nil ? "本地译文已就绪" : "本地补译已就绪"
            self.onStatus?(unavailable.isEmpty ? success : unavailable.joined(separator: "\n"))
        }
    }

    private func translateWithHost(requests: [TranslationSession.Request], source: Locale.Language,
                                   target: Locale.Language) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            pendingID = UUID()
            pending = PendingBatch(id: pendingID, requests: requests, continuation: continuation)
            var config: TranslationSession.Configuration
            if #available(macOS 26.4, *) {
                config = .init(source: source, target: target, preferredStrategy: .lowLatency)
            } else { config = .init(source: source, target: target) }
            config.invalidate()
            configuration = config
        }
    }

    private func translate(_ requests: [TranslationSession.Request], using session: TranslationSession) async throws -> [String: String] {
        let sources = Dictionary(uniqueKeysWithValues: requests.compactMap { request in
            request.clientIdentifier.map { ($0, request.sourceText) }
        })
        var translations: [String: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                try Task.checkCancellation()
                guard let id = response.clientIdentifier, let source = sources[id] else { continue }
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { translations[source] = text }
            }
        } catch {
            try Task.checkCancellation()
            // Keep the responses delivered before an individual request failed.
            guard !translations.isEmpty else { throw error }
            DiagnosticLogger.shared.warning("Local translation batch interrupted: \(error.localizedDescription)")
            return translations
        }
        let missing = requests.filter { translations[$0.sourceText] == nil }
        for request in missing.prefix(2) {
            try Task.checkCancellation()
            do {
                let response = try await session.translate(request.sourceText)
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { translations[request.sourceText] = text }
            } catch {
                try Task.checkCancellation()
                DiagnosticLogger.shared.warning("Local translation line retry failed: \(error.localizedDescription)")
            }
        }
        return translations
    }

    func run(session: TranslationSession, id: UUID) async {
        guard let work = pending, work.id == id else { return }
        activeSession = session
        defer { if activeSession === session { activeSession = nil } }
        do {
            // macOS 15 requires a view-backed session. Recheck its languages before using it.
            guard let source = session.sourceLanguage, let target = session.targetLanguage,
                  await translationLanguageAvailability().status(from: source, to: target) == .installed else {
                throw MissingLanguagePack()
            }
            guard pending?.id == work.id else { return }
            try Task.checkCancellation()
            let response = try await translate(work.requests, using: session)
            guard pending?.id == work.id else { return }
            finishPending(.success(response))
        } catch {
            guard pending?.id == work.id else { return }
            finishPending(.failure(error))
        }
    }

    private func finishPending(_ result: Result<[String: String], Error>) {
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
