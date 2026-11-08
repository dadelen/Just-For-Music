import Foundation
import XCTest
@testable import AppleMusicLyrics

final class OnlineTranslationTests: XCTestCase {
    func testModelsUsesTheSameServiceBaseAndReturnsDistinctModelIDs() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let config = OnlineTranslationConfiguration(baseURL: " https://example.test/proxy/v1/chat/completions/ ", model: "")
        StubTranslationProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/proxy/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertNil(request.httpBody)
            let data = Data(#"{"data":[{"id":"model-2"},{"id":"model-1"},{"id":"model-2"}]}"#.utf8)
            return (200, data)
        }
        let models = try await OnlineTranslationClient(session: session).models(using: config, key: "test-key")
        XCTAssertEqual(models, ["model-1", "model-2"])
        let loopback = OnlineTranslationConfiguration(baseURL: "http://[::1]:11434/v1", model: "x")
        XCTAssertEqual(try loopback.endpoint().absoluteString, "http://[::1]:11434/v1/chat/completions")
    }

    func testExistingConfigurationMigratesAndOtherProfilesDoNotChangeSelection() throws {
        let defaults = UserDefaults.standard
        let legacyKey = "translation.online.configuration"
        let profilesKey = "translation.online.profiles"
        let previousLegacy = defaults.object(forKey: legacyKey)
        let previousProfiles = defaults.object(forKey: profilesKey)
        defer {
            defaults.set(previousLegacy, forKey: legacyKey)
            defaults.set(previousProfiles, forKey: profilesKey)
        }
        defaults.removeObject(forKey: profilesKey)
        defaults.set(Data(#"{"baseURL":"https://example.test/v1","model":"old-model"}"#.utf8), forKey: legacyKey)
        AppPreferences.migrate()
        var profiles = AppPreferences.onlineTranslationProfiles
        let migrated = try XCTUnwrap(profiles.entries.first)
        XCTAssertEqual(profiles.activeID, migrated.id)
        XCTAssertEqual(migrated.configuration.model, "old-model")
        XCTAssertNil(migrated.configuration.credentialID)

        let id = UUID()
        let other = OnlineTranslationConfiguration(baseURL: migrated.configuration.baseURL, model: "new-model", credentialID: id)
        profiles.save(.init(id: id, configuration: other))
        AppPreferences.onlineTranslationProfiles = profiles
        XCTAssertEqual(AppPreferences.onlineTranslationProfiles.entries.count, 2)
        XCTAssertEqual(AppPreferences.onlineTranslationProfiles.activeID, migrated.id)
        profiles.remove(migrated.id)
        XCTAssertNil(profiles.activeConfiguration)
        XCTAssertEqual(profiles.entries.first?.configuration, other)
    }

    func testClientUsesConfiguredEndpointAndMapsResponsesByID() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let config = OnlineTranslationConfiguration(baseURL: "https://example.test/v1/", model: "test-model")
        let input: [OnlineTranslationClient.Line] = [.init(id: 4, text: "A quiet night"), .init(id: 8, text: "A bright moon"),
                                                     .init(id: 11, text: "我在这里等你 tonight。")]
        StubTranslationProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try Self.body(request)
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertNil(body["thinking"])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let text = try XCTUnwrap(messages.last?["content"])
            let lines = try JSONDecoder().decode([OnlineTranslationClient.Line].self, from: Data(text.utf8))
            XCTAssertEqual(lines, input)
            return (200, try Self.response([.init(id: 8, text: "明月"), .init(id: 99, text: "无关内容"),
                                            .init(id: 4, text: "静夜"), input[2]]))
        }
        let result = try await OnlineTranslationClient(session: session).translate(input, using: config, key: "test-key")
        XCTAssertEqual(result, [4: "静夜", 8: "明月"])
        XCTAssertThrowsError(try OnlineTranslationConfiguration(baseURL: "http://example.test/v1", model: "x").validated())
    }

    @MainActor
    func testServiceLetsModelIdentifyLanguageAndCachesIntentionalSkips() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(directory: directory)
        let client = OnlineTranslationClient(session: session)
        let first = OnlineTranslationService(cache: cache, client: client, readKey: { _ in "test-key" })
        let track = TrackInfo(title: "Sample", artist: "Artist", album: "Album", duration: 15, position: 0, state: .playing)
        let repeated = "The moon is bright tonight"
        let mixed = "我们在这里 tonight"
        let chinese = "那些明亮的日子"
        let document = LyricsDocument(lines: [
            .init(time: 1, text: repeated),
            .init(time: 2, text: "I can see the stars above", translation: "我能看见星星", translationLanguage: "zh-Hans"),
            .init(time: 3, text: mixed),
            .init(time: 4, text: repeated),
            .init(time: 5, text: chinese),
            .init(time: 6, text: "Listen to the sound of the sea", translation: "听听大海的声音")
        ], plainText: nil, source: "test", isSynced: true, wordTiming: .none, sourceLanguage: "en")
        StubTranslationProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let text = try XCTUnwrap(messages.last?["content"])
            let lines = try JSONDecoder().decode([OnlineTranslationClient.Line].self, from: Data(text.utf8))
            XCTAssertEqual(lines, [.init(id: 0, text: repeated), .init(id: 2, text: mixed), .init(id: 4, text: chinese)])
            return (200, try Self.response([.init(id: 0, text: "今晚月色明亮"), .init(id: 2, text: ""), .init(id: 4, text: "")]))
        }
        let firstResult = expectation(description: "translated missing lyrics")
        var status = ""
        first.onStatus = { status = $0 }
        first.onFallback = { _, _, _ in XCTFail("Explicit skips should not trigger local fallback") }
        first.onResult = { result in
            XCTAssertEqual(result.lines.map(\.translation), ["今晚月色明亮", "我能看见星星", nil, "今晚月色明亮", nil, "听听大海的声音"])
            XCTAssertEqual(result.lines.map(\.time), document.lines.map(\.time))
            firstResult.fulfill()
        }
        first.start(document: document, track: track, configuration: .zhipu)
        await fulfillment(of: [firstResult], timeout: 3)
        XCTAssertTrue(status.contains("已发起 1 次请求，收到 1 次 HTTP 响应"))

        let cached = OnlineTranslationService(cache: cache, client: client, readKey: { _ in
            XCTFail("A complete cached translation should not need credentials.")
            return nil
        })
        let cachedResult = expectation(description: "served from cache")
        cached.onStatus = { status = $0 }
        cached.onFallback = { _, _, _ in XCTFail("Cached skips should not trigger local fallback") }
        cached.onResult = { result in
            XCTAssertEqual(result.lines[3].translation, "今晚月色明亮")
            cachedResult.fulfill()
        }
        cached.start(document: document, track: track, configuration: .zhipu)
        await fulfillment(of: [cachedResult], timeout: 3)
        XCTAssertTrue(status.contains("缓存命中 4 行"))
        XCTAssertTrue(status.contains("尚未发起联网请求"))
    }

    @MainActor
    func testSongLanguageIsResolvedBeforeAnyRequest() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = OnlineTranslationService(cache: TranslationCache(directory: directory),
                                               client: OnlineTranslationClient(session: session),
                                               readKey: { _ in "test-key" })
        let english = ["The night is still bright", "We can hear the ocean"]
        var requests = 0
        StubTranslationProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(requests, 1)
            let body = try Self.body(request)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let input = try XCTUnwrap(messages.last?["content"])
            XCTAssertEqual(try JSONDecoder().decode([OnlineTranslationClient.Line].self, from: Data(input.utf8)).map(\.text), english)
            return (200, try Self.response([.init(id: 0, text: "夜晚依旧明亮"), .init(id: 1, text: "我们能听见海浪")]))
        }
        service.onResult = { _ in XCTFail("Chinese songs should keep their original lyrics") }
        service.onFallback = { _, _, _ in XCTFail("A confirmed Chinese song should not use fallback") }
        let skipped: [(title: String, language: String?, texts: [String], reason: String)] = [
            ("Tagged Chinese", "zh-Hans", english, "以中文为主"),
            ("Untagged Han", nil, ["未来", "夜空"], "无法确认"),
            ("Untagged mixed", nil, ["未来", "夜空", "I still remember the lights"], "无法确认")
        ]
        for (title, language, texts, reason) in skipped {
            let track = TrackInfo(title: title, artist: "", album: "", duration: 15, position: 0, state: .playing)
            let lines = texts.enumerated().map { LyricLine(time: Double($0.offset), text: $0.element) }
            let document = LyricsDocument(lines: lines, plainText: nil, source: "test", isSynced: true,
                                          wordTiming: .none, sourceLanguage: language)
            let complete = expectation(description: "Chinese song skipped: \(title)")
            service.onStatus = { status in
                if status.contains(reason) {
                    XCTAssertTrue(status.contains("尚未发起联网请求"))
                    complete.fulfill()
                }
            }
            service.start(document: document, track: track, configuration: .zhipu)
            await fulfillment(of: [complete], timeout: 3)
        }
        XCTAssertEqual(requests, 0)

        let translated = expectation(description: "Untagged foreign song goes directly to translation")
        service.onStatus = { status in
            if status.contains("译文 2 行") {
                XCTAssertTrue(status.contains("已发起 1 次请求，收到 1 次 HTTP 响应"))
                translated.fulfill()
            }
        }
        service.onResult = { XCTAssertEqual($0.lines.map(\.translation), ["夜晚依旧明亮", "我们能听见海浪"]) }
        let document = LyricsDocument(lines: english.enumerated().map { LyricLine(time: Double($0.offset), text: $0.element) },
                                      plainText: nil, source: "test", isSynced: true, wordTiming: .none)
        let track = TrackInfo(title: "Untagged English", artist: "", album: "", duration: 15, position: 0, state: .playing)
        service.start(document: document, track: track, configuration: .zhipu)
        await fulfillment(of: [translated], timeout: 3)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testZhipuModelOverloadRetriesOnceAndPublishesTheTranslation() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = OnlineTranslationService(cache: TranslationCache(directory: directory),
                                               client: OnlineTranslationClient(session: session),
                                               readKey: { _ in "test-key" })
        var requests = 0
        StubTranslationProtocol.handler = { _ in
            requests += 1
            if requests == 1 {
                return (429, Data(#"{"error":{"code":"1305","message":"overloaded"}}"#.utf8))
            }
            return (200, try Self.response([.init(id: 0, text: "海面风平浪静")]))
        }
        let completed = expectation(description: "One retry recovers the translation")
        var statuses: [String] = []
        service.onStatus = { statuses.append($0) }
        service.onFallback = { _, _, _ in XCTFail("The retry should succeed before falling back") }
        service.onResult = { document in
            XCTAssertEqual(document.lines.first?.translation, "海面风平浪静")
            completed.fulfill()
        }
        let document = LyricsDocument(lines: [.init(time: 1, text: "The sea is quiet tonight")], plainText: nil,
                                      source: "test", isSynced: true, wordTiming: .none, sourceLanguage: "en")
        let track = TrackInfo(title: "Retry", artist: "", album: "", duration: 15, position: 0, state: .playing)
        service.start(document: document, track: track, configuration: .zhipu)
        await fulfillment(of: [completed], timeout: 6)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(statuses.contains { $0.contains("1305") && $0.contains("重试一次") })
    }

    @MainActor
    func testRateLimitAndPartialResponseUseLocalTranslationOnlyForMissingLines() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Local translation requires macOS 15") }
        let preference = AppPreferences.automaticTranslationKey
        let original = UserDefaults.standard.object(forKey: preference)
        defer { UserDefaults.standard.set(original, forKey: preference) }
        AppPreferences.automaticTranslation = true

        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(directory: directory)
        let document = LyricsDocument(lines: [
            .init(time: 1, text: "The moon is bright tonight"),
            .init(time: 2, text: "The wind carries us home"),
            .init(time: 3, text: "I can see the stars above", translation: "我能看见星星", translationLanguage: "zh-Hans")
        ], plainText: nil, source: "test", isSynced: true, wordTiming: .none, sourceLanguage: "en")
        let endpoint = try OnlineTranslationConfiguration.zhipu.endpoint()

        for statusCode in [429, 200] {
            let track = TrackInfo(title: "Fallback \(statusCode)", artist: "", album: "", duration: 15, position: 0, state: .playing)
            let onlineKey = TranslationCache.onlineKey(track: track, document: document, endpoint: endpoint,
                                                      model: OnlineTranslationConfiguration.zhipu.model)
            let localKey = TranslationCache.key(track: track, document: document, source: "en",
                                               target: AppPreferences.translationTarget, quality: false)
            if statusCode == 429 { await cache.write([0: "今晚月色明亮"], key: onlineKey) }
            await cache.write([0: "旧的本地译文", 1: "风载我们回家"], key: localKey)
            StubTranslationProtocol.handler = { _ in
                let data = statusCode == 429 ? Data(#"{"error":{"code":1113}}"#.utf8)
                    : try Self.response([.init(id: 0, text: "今晚月色明亮")])
                return (statusCode, data)
            }

            let local = LocalTranslationService(cache: cache)
            let online = OnlineTranslationService(cache: cache, client: OnlineTranslationClient(session: session),
                                                  readKey: { _ in "test-key" })
            let result = expectation(description: "Local fallback after HTTP \(statusCode)")
            local.onResult = { lyrics in
                XCTAssertEqual(lyrics.lines.map(\.translation), ["今晚月色明亮", "风载我们回家", "我能看见星星"])
                XCTAssertEqual(lyrics.lines.map(\.time), document.lines.map(\.time))
                result.fulfill()
            }
            online.onFallback = { document, track, fallback in
                XCTAssertEqual(fallback.pendingLineIDs, [1])
                if statusCode == 429 {
                    XCTAssertTrue(fallback.reason.contains("1113"))
                    XCTAssertTrue(fallback.reason.contains("欠费"))
                }
                local.startFallback(document: document, track: track, pendingLineIDs: fallback.pendingLineIDs,
                                    onlineTranslations: fallback.onlineTranslations)
            }
            online.start(document: document, track: track, configuration: .zhipu)
            await fulfillment(of: [result], timeout: 3)
            let persistedOnline = await cache.read(onlineKey)
            XCTAssertEqual(persistedOnline, [0: "今晚月色明亮"])
        }
    }

    func testLiveZhipuWhenExplicitlyEnabled() async throws {
        guard let key = ProcessInfo.processInfo.environment["AML_ZHIPU_INTEGRATION_KEY"], !key.isEmpty else {
            throw XCTSkip("Set AML_ZHIPU_INTEGRATION_KEY to run the live Zhipu test")
        }
        let output = try await OnlineTranslationClient().translate(
            [.init(id: 3, text: "The moon is bright tonight."), .init(id: 7, text: "The wind is gentle."),
             .init(id: 8, text: "We follow the light home."), .init(id: 9, text: "我在这里等你 tonight。")],
            using: .zhipu, key: key
        )
        XCTAssertTrue(output[9]?.isEmpty ?? true)
        for id in [3, 7, 8] {
            XCTAssertNotNil(output[id]?.range(of: #"\p{Han}"#, options: .regularExpression))
        }
    }

    @MainActor
    func testSwitchingSongsWhileRequestIsInFlightPublishesOnlyNewLyrics() async throws {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = OnlineTranslationService(cache: TranslationCache(directory: directory),
                                               client: OnlineTranslationClient(session: session),
                                               readKey: { _ in "test-key" })
        let first = "The moon is bright tonight"
        let second = "The summer wind carries us home"
        let firstRequest = expectation(description: "first request in flight")
        StubTranslationProtocol.handler = { request in
            let body = try Self.body(request)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let text = try XCTUnwrap(messages.last?["content"])
            if text.contains(first) {
                firstRequest.fulfill()
                return nil // Wait until the service cancels the request.
            }
            XCTAssertTrue(text.contains(second))
            return (200, try Self.response([.init(id: 0, text: "夏风载我们回家")]))
        }
        let newResult = expectation(description: "new song lyrics")
        service.onResult = { result in
            XCTAssertEqual(result.lines.first?.text, second)
            XCTAssertEqual(result.lines.first?.translation, "夏风载我们回家")
            newResult.fulfill()
        }
        func start(title: String, text: String) {
            let document = LyricsDocument(lines: [.init(time: 1, text: text)], plainText: nil, source: "test",
                                          isSynced: true, wordTiming: .none, sourceLanguage: "en")
            let track = TrackInfo(title: title, artist: "", album: "", duration: 15, position: 0, state: .playing)
            service.start(document: document, track: track, configuration: .zhipu)
        }
        start(title: "One", text: first)
        await fulfillment(of: [firstRequest], timeout: 3)
        start(title: "Two", text: second)
        await fulfillment(of: [newResult], timeout: 3)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTranslationProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func response(_ lines: [OnlineTranslationClient.Line]) throws -> Data {
        let entries: [[String: Any]] = lines.map { ["id": $0.id, "text": $0.text] }
        let json = try JSONSerialization.data(withJSONObject: ["translations": entries])
        return try completion(String(decoding: json, as: UTF8.self))
    }

    private static func completion(_ content: String) throws -> Data {
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
    }
}

private final class StubTranslationProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (statusCode: Int, data: Data)?)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            guard let result = try handler(request) else { return }
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: result.statusCode,
                                                        httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
