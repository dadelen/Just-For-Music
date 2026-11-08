import AppKit
import SwiftUI

struct OnlineTranslationSettings: View {
    let onSaved: () -> Void
    @State private var profiles: OnlineTranslationProfiles
    @State private var draft: OnlineTranslationConfiguration
    @State private var editingID: UUID?
    @State private var apiKey = ""
    @State private var message = ""
    @State private var models: [String] = []
    @State private var requestTask: Task<Void, Never>?
    @State private var removing: OnlineTranslationProfiles.Profile?

    init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        let profiles = AppPreferences.onlineTranslationProfiles
        _profiles = State(initialValue: profiles)
        _editingID = State(initialValue: profiles.activeID)
        _draft = State(initialValue: profiles.activeConfiguration ?? .init(baseURL: "", model: ""))
    }

    var body: some View {
        Section(editingID == nil ? "新增大模型 API" : "编辑大模型 API") {
            editor.disabled(requestTask != nil)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        Section("已保存的 API") {
            if profiles.entries.isEmpty {
                Text("暂无已保存的 API").foregroundStyle(.secondary)
            }
            ForEach(profiles.entries) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.configuration.model).fontWeight(.medium).lineLimit(1)
                        Text(profile.configuration.baseURL)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(profile.configuration.baseURL)
                    Spacer()
                    if profiles.activeID == profile.id {
                        Label("正在使用", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button("使用") { activate(profile.id) }
                    }
                    Button("编辑") { edit(profile) }
                    Button("删除") { removing = profile }
                }
            }
            .disabled(requestTask != nil)
        }
        .alert("删除 API 配置？", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { profile in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { remove(profile) }
        } message: { _ in
            Text("将同时从钥匙串移除此配置的 API Key。")
        }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            apiKey = ""
        }
    }

    @ViewBuilder private var editor: some View {
        TextField("API 地址", text: Binding(get: { draft.baseURL }, set: { address in
            let previous = try? draft.endpoint()
            draft.baseURL = address
            if previous != (try? draft.endpoint()) {
                draft.model = ""
                apiKey = ""
                models = []
            }
        }), prompt: Text("https://服务地址/v1"))
        SecureField("API Key", text: $apiKey, prompt: Text("按服务要求填写"))
            .onChange(of: apiKey) { _ in models = [] }
            .contextMenu {
                Button("复制 API Key", action: copyAPIKey)
                Button("粘贴 API Key", action: pasteAPIKey)
            }
        if models.isEmpty {
            TextField("模型", text: $draft.model, prompt: Text("获取模型或手动填写模型 ID"))
        } else {
            Picker("模型", selection: $draft.model) {
                Text("请选择模型").tag("")
                ForEach(models, id: \.self) { model in Text(model).tag(model) }
            }
        }
        HStack {
            Button("获取模型", action: fetchModels)
            Button("测试连接", action: testConnection)
            Button("保存", action: save)
            if editingID != nil { Button("新增 API") { edit(nil) } }
        }
        Text("支持 OpenAI 兼容接口。可填 API 基础地址（如 …/v1）或完整 Chat Completions 地址。密钥保存在 macOS 钥匙串。")
            .font(.caption).foregroundStyle(.secondary)
        Text("只翻译明确以外语为主的歌曲。优先使用语种标注，缺少标注时在本机识别。测试连接只发送固定示例句。")
            .font(.caption).foregroundStyle(.secondary)
        Text("联网失败或漏译时，使用已安装语言包进行本地补译。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var editedProfile: OnlineTranslationProfiles.Profile? {
        profiles.entries.first { $0.id == editingID }
    }

    private var enteredKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func savedConfiguration(matching config: OnlineTranslationConfiguration) -> OnlineTranslationConfiguration? {
        guard let saved = editedProfile?.configuration, let endpoint = try? config.endpoint(),
              (try? saved.endpoint()) == endpoint else { return nil }
        return saved
    }

    private func credential(for config: OnlineTranslationConfiguration) throws -> String? {
        if !enteredKey.isEmpty { return enteredKey }
        guard let saved = savedConfiguration(matching: config) else { return nil }
        return try OnlineTranslationKeychain.read(for: saved)
    }

    private func pasteAPIKey() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            message = "剪贴板没有可粘贴的文本。"
            return
        }
        apiKey = text
        message = "已粘贴 API Key。"
    }

    private func copyAPIKey() {
        do {
            guard let key = try credential(for: draft), !key.isEmpty else { throw OnlineTranslationError.missingKey }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            message = pasteboard.setString(key, forType: .string) ? "已复制 API Key。" : "无法写入剪贴板。"
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do {
            var config = try draft.validated()
            let id = editingID ?? UUID()
            let previous = editedProfile?.configuration
            let sameAddress = savedConfiguration(matching: config)
            if let sameAddress { config.credentialID = sameAddress.credentialID }
            else { config.credentialID = id }
            if !enteredKey.isEmpty {
                try OnlineTranslationKeychain.save(enteredKey, for: config)
            }
            if let previous, sameAddress == nil {
                do { try OnlineTranslationKeychain.remove(for: previous) }
                catch {
                    if !enteredKey.isEmpty { try? OnlineTranslationKeychain.remove(for: config) }
                    throw error
                }
            }
            let wasActive = profiles.activeID == id
            profiles.save(.init(id: id, configuration: config))
            AppPreferences.onlineTranslationProfiles = profiles
            editingID = id
            draft = config
            apiKey = ""
            message = "API 配置已保存。"
            if wasActive || profiles.activeID == id { onSaved() }
        } catch { message = error.localizedDescription }
    }

    private func activate(_ id: UUID) {
        profiles.activeID = id
        AppPreferences.onlineTranslationProfiles = profiles
        message = "已切换正在使用的 API。"
        onSaved()
    }

    private func edit(_ profile: OnlineTranslationProfiles.Profile?) {
        editingID = profile?.id
        draft = profile?.configuration ?? .init(baseURL: "", model: "")
        apiKey = ""
        models = []
        message = ""
    }

    private func remove(_ profile: OnlineTranslationProfiles.Profile) {
        do {
            try OnlineTranslationKeychain.remove(for: profile.configuration)
            let wasActive = profiles.activeID == profile.id
            profiles.remove(profile.id)
            AppPreferences.onlineTranslationProfiles = profiles
            if editingID == profile.id { edit(nil) }
            message = "已删除 API 配置。"
            if wasActive { onSaved() }
        } catch { message = error.localizedDescription }
    }

    private func fetchModels() {
        do {
            let config = draft
            _ = try config.modelsEndpoint()
            let key = try credential(for: config)
            message = "正在获取模型…"
            requestTask = Task { @MainActor in
                do {
                    let available = try await OnlineTranslationClient().models(using: config, key: key)
                    guard !Task.isCancelled else { return }
                    models = available
                    if !available.contains(draft.model) {
                        draft.model = available.count == 1 ? (available.first ?? "") : ""
                    }
                    message = "已获取 \(available.count) 个模型。"
                } catch {
                    guard !Task.isCancelled else { return }
                    models = []
                    message = "\(error.localizedDescription) 可手动填写模型 ID。"
                }
                requestTask = nil
            }
        } catch { message = error.localizedDescription }
    }

    private func testConnection() {
        do {
            let config = try draft.validated()
            let key = try credential(for: config)
            message = "正在测试连接…"
            requestTask = Task { @MainActor in
                do {
                    let result = try await OnlineTranslationClient().translate(
                        [.init(id: 0, text: "The moon is bright tonight.")], using: config, key: key)
                    guard !Task.isCancelled else { return }
                    guard let sample = result[0], !sample.isEmpty else { throw OnlineTranslationError.invalidResponse }
                    message = "连接成功。示例译文：\(sample)"
                } catch {
                    guard !Task.isCancelled else { return }
                    message = error.localizedDescription
                }
                requestTask = nil
            }
        } catch { message = error.localizedDescription }
    }
}
