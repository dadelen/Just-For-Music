import Foundation

@MainActor
final class OnlineTranslationService {
    var onStatus: ((String) -> Void)?
    var onResult: ((LyricsDocument) -> Void)?
    var onFallback: ((LyricsDocument, TrackInfo, Fallback) -> Void)?
    private(set) var fallback: Fallback?
    private let cache: TranslationCache
    private let client: OnlineTranslationClient
    private let readKey: @Sendable (OnlineTranslationConfiguration) throws -> String?
    private var task: Task<Void, Never>?
    private var current: Work?
    private var generation = UUID()
    private var lastStatus: String?
    private var requests = 0
    private var responses = 0
    private var latestHTTPStatus: Int?

    private struct Work: Equatable {
        let document: LyricsDocument
        let trackKey: String
        let configuration: OnlineTranslationConfiguration
    }

    struct Fallback {
        let pendingLineIDs: Set<Int>
        let onlineTranslations: [Int: String]
        let reason: String
    }

    init(cache: TranslationCache = TranslationCache(), client: OnlineTranslationClient = OnlineTranslationClient(),
         readKey: @escaping @Sendable (OnlineTranslationConfiguration) throws -> String? = { try OnlineTranslationKeychain.read(for: $0) }) {
        self.cache = cache
        self.client = client
        self.readKey = readKey
    }

    func cancel() {
        task?.cancel()
        task = nil
        current = nil
        fallback = nil
        lastStatus = nil
        requests = 0
        responses = 0
        latestHTTPStatus = nil
        generation = UUID()
    }

    func suspend() {
        guard task != nil else { return }
        let summary = requestSummary
        cancel()
        report("已暂停联网翻译。\n\(summary)")
    }

    var statusWhileHidden: String {
        let status = lastStatus ?? "尚未发起联网请求。"
        return "显示桌面译文后才会发起新请求。\n\(status)"
    }

    func start(document: LyricsDocument, track: TrackInfo, configuration: OnlineTranslationConfiguration) {
        let work = Work(document: document, trackKey: track.identityKey, configuration: configuration)
        if current == work {
            if fallback == nil, let lastStatus { onStatus?(lastStatus) }
            if let fallback { onFallback?(document, track, fallback) }
            return
        }
        cancel()
        current = work
        let token = generation
        report("尚未发起联网请求。正在确认当前歌曲的语种。")
        task = Task { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            defer { if self.generation == token { self.task = nil } }

            let language = await Task.detached(priority: .utility) {
                LyricsLanguageDetector.songLanguage(for: document)
            }.value
            guard self.isCurrent(token) else { return }
            guard language == .foreign else {
                let reason: String
                switch language {
                case .chinese: reason = "当前歌曲以中文为主，已保留原文。"
                case .uncertain: reason = "本机无法确认当前歌曲以外语为主，已保留原文。"
                case .foreign: return
                }
                self.report("尚未发起联网请求。\(reason)")
                return
            }
            let eligible = document.lines.enumerated().compactMap { index, line -> OnlineTranslationClient.Line? in
                guard !line.isGap, !line.hasPreferredOriginalTranslation,
                      !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .init(id: index, text: line.text)
            }
            guard !eligible.isEmpty else {
                self.report("尚未发起联网请求。当前歌词已有译文，或没有需要翻译的行。")
                return
            }
            var resolved: [Int: String] = [:]
            var failure: String?
            do {
                let config = try configuration.validated()
                let cacheKey = TranslationCache.onlineKey(track: track, document: document, endpoint: try config.endpoint(),
                                                          model: config.model, credentialID: config.credentialID)
                let cached = await self.cache.read(cacheKey) ?? [:]
                guard self.isCurrent(token) else { return }
                let byText = Dictionary(grouping: eligible, by: \.text)
                var missing: [OnlineTranslationClient.Line] = []
                var seen: Set<String> = []
                for line in eligible where seen.insert(line.text).inserted {
                    let repeated = byText[line.text] ?? []
                    if let existing = repeated.compactMap({ cached[$0.id] }).first {
                        for occurrence in repeated { resolved[occurrence.id] = existing }
                    } else { missing.append(line) }
                }
                self.publish(resolved, for: document)
                let cachedLines = resolved.count
                if !missing.isEmpty {
                    let readKey = self.readKey
                    let key = try await Task.detached(priority: .utility) { try readKey(config) }.value
                    guard self.isCurrent(token) else { return }
                    var canRetryRateLimit = true
                    let batches = Self.batches(missing)
                    for (index, batch) in batches.enumerated() {
                        guard self.isCurrent(token) else { return }
                        let purpose = "翻译第 \(index + 1)/\(batches.count) 批歌词"
                        let event = self.requestEvents(for: config.model, purpose: purpose, token: token)
                        let output = try await self.request(retryAvailable: &canRetryRateLimit) {
                            try await self.client.translate(batch, using: config, key: key, onEvent: event)
                        }
                        guard self.isCurrent(token) else { return }
                        for line in batch {
                            guard let result = output[line.id] else { continue }
                            for occurrence in byText[line.text] ?? [] { resolved[occurrence.id] = result }
                        }
                        await self.cache.write(resolved, key: cacheKey)
                        guard self.isCurrent(token) else { return }
                        self.publish(resolved, for: document)
                    }
                }
                if resolved.count == eligible.count {
                    let translated = resolved.values.filter { !$0.isEmpty }.count
                    let skipped = resolved.count - translated
                    self.report("译文 \(translated) 行，跳过 \(skipped) 行，缓存命中 \(cachedLines) 行。\n\(self.requestSummary)")
                    return
                }
            } catch {
                failure = error.localizedDescription
            }
            guard self.isCurrent(token) else { return }
            let pendingLineIDs = Set(eligible.map(\.id)).subtracting(resolved.keys)
            guard !pendingLineIDs.isEmpty else { return }
            let reason = failure ?? "联网译文缺少 \(pendingLineIDs.count) 行。"
            let fallback = Fallback(pendingLineIDs: pendingLineIDs, onlineTranslations: resolved.filter { !$0.value.isEmpty },
                                    reason: "\(reason) 已转为本地补译。\n\(self.requestSummary)")
            self.fallback = fallback
            self.report(fallback.reason)
            self.onFallback?(document, track, fallback)
        }
    }

    private var requestSummary: String {
        guard requests > 0 else { return "尚未发起联网请求。" }
        let status = latestHTTPStatus.map { "，最近响应 HTTP \($0)" } ?? ""
        return "已发起 \(requests) 次请求，收到 \(responses) 次 HTTP 响应\(status)。"
    }

    private func report(_ status: String) {
        lastStatus = status
        onStatus?(status)
    }

    private func requestEvents(for model: String, purpose: String, token: UUID) -> OnlineTranslationClient.RequestEventHandler {
        { [weak self] event in
            guard let self, self.isCurrent(token) else { return }
            switch event {
            case .started:
                self.requests += 1
                self.report("正在请求 \(model) \(purpose)。\n\(self.requestSummary)")
            case .response(let status):
                self.responses += 1
                self.latestHTTPStatus = status
                self.report("已收到 \(model) 的响应，正在处理。\n\(self.requestSummary)")
            }
        }
    }

    private func request<Result>(retryAvailable: inout Bool, perform: () async throws -> Result) async throws -> Result {
        do {
            return try await perform()
        } catch let error as OnlineTranslationError {
            guard retryAvailable, let delay = error.shortRetryDelay else { throw error }
            retryAvailable = false
            report("\(error.localizedDescription) 稍后自动重试一次…\n\(requestSummary)")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try Task.checkCancellation()
            return try await perform()
        }
    }

    private func publish(_ resolved: [Int: String], for document: LyricsDocument) {
        let translations = resolved.filter { !$0.value.isEmpty }
        if !translations.isEmpty { onResult?(document.applyingMachineTranslations(translations)) }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        generation == token && !Task.isCancelled
    }

    private static func batches(_ lines: [OnlineTranslationClient.Line]) -> [[OnlineTranslationClient.Line]] {
        var batches: [[OnlineTranslationClient.Line]] = []
        var batch: [OnlineTranslationClient.Line] = []
        var bytes = 0
        for line in lines {
            let size = line.text.utf8.count
            if !batch.isEmpty, batch.count == 24 || bytes + size > 4_000 {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(line)
            bytes += size
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}
