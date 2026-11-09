import AppKit
import SwiftUI

@MainActor
final class SettingsActions: ObservableObject {
    @Published var updateStatus = "更新源待配置"
    @Published var translationStatus = "等待歌词"
    @Published var languagePackRevision = 0
    @Published var isWindowKey = false
    @Published var checkingUpdates = false
    var refresh: (() -> Void)?
    var checkUpdates: (() -> Void)?
    var retryLocalTranslation: (() -> Void)?
    var onlineTranslationConfigurationChanged: (() -> Void)?
    var retryOnlineTranslation: (() -> Void)?
    var floatingLyricsColorChanged: (() -> Void)?
    var floatingLyricsFontSizeChanged: (() -> Void)?
    var previewGlassTransparency: ((Double) -> Void)?
    var floatingLyricsShadowChanged: (() -> Void)?
    var floatingPositionLockChanged: (() -> Void)?
    private var pendingFontScale: Double?
    private var fontSizePreviewTimer: Timer?

    func previewFloatingLyricsFontSize(_ value: Double) {
        pendingFontScale = value
        guard fontSizePreviewTimer == nil else { return }
        // Coalesce drag events, including those delivered in AppKit's tracking mode.
        let timer = Timer(timeInterval: 0.06, repeats: false) { [weak self] _ in
            // This timer is installed only on the main run loop, including during drag tracking.
            MainActor.assumeIsolated { self?.flushFloatingLyricsFontSize() }
        }
        fontSizePreviewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func flushFloatingLyricsFontSize() {
        fontSizePreviewTimer?.invalidate()
        fontSizePreviewTimer = nil
        guard let value = pendingFontScale else { return }
        pendingFontScale = nil
        guard AppPreferences.fontScale != value else { return }
        AppPreferences.fontScale = value
        floatingLyricsFontSizeChanged?()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) { actions.isWindowKey = true }
    func windowDidResignKey(_ notification: Notification) { actions.isWindowKey = false }
    func windowWillClose(_ notification: Notification) {
        actions.flushFloatingLyricsFontSize()
    }
    let actions = SettingsActions()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let size = NSSize(width: 700, height: 540)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.delegate = self
            window.title = "\(AppIdentity.name) 设置"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.isReleasedWhenClosed = false
            let surface = GlassSurface()
            let host = NSHostingView(rootView: SettingsView(actions: actions))
            host.translatesAutoresizingMaskIntoConstraints = false
            surface.content.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor),
                host.topAnchor.constraint(equalTo: surface.content.topAnchor, constant: 30),
                host.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor)
            ])
            window.contentView = surface
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case desktopLyrics = "桌面歌词"
        case menuBar = "菜单栏"
        case lyricEffects = "歌词效果"
        case translation = "翻译"
        case maintenance = "维护"

        var id: Self { self }

        var icon: String {
            switch self {
            case .desktopLyrics: return "macwindow"
            case .menuBar: return "menubar.rectangle"
            case .lyricEffects: return "text.quote"
            case .translation: return "character.bubble"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }
    }

    @ObservedObject var actions: SettingsActions
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selection: Page = .desktopLyrics
    @AppStorage("floatingLyrics.visible") private var visible = true
    @AppStorage(AppPreferences.statusBarModeKey) private var statusMode: StatusBarMode = .automatic
    @AppStorage(AppPreferences.floatingLyricsModeKey) private var floatingMode: FloatingLyricsMode = .vinyl
    @AppStorage(AppPreferences.floatingPositionLockKey) private var floatingPositionLocked = false
    @AppStorage(AppPreferences.floatingLyricsShadowKey) private var floatingLyricsShadow = true
    @AppStorage("floatingLyrics.spaceBehavior") private var spaces = "allSpaces"
    @AppStorage("floatingLyrics.showOverFullScreen") private var fullScreen = true
    @AppStorage("floatingLyrics.showTranslation") private var translation = true
    @AppStorage("floatingLyrics.showTransliteration") private var transliteration = true
    @AppStorage(AppPreferences.automaticTranslationKey) private var automaticTranslation = false
    @AppStorage(AppPreferences.translationProviderKey) private var translationProvider: TranslationProvider = .local
    @State private var installedSourceLanguages: [String]?
    @AppStorage("lyrics.smoothScrolling") private var smooth = true
    @AppStorage("lyrics.gapAnimation") private var gaps = true
    @State private var fontScale = AppPreferences.fontScale
    @State private var activeColor = Color(nsColor: AppPreferences.menuBarLyricsActiveColor)
    @State private var inactiveColor = Color(nsColor: AppPreferences.menuBarLyricsInactiveColor)
    @State private var floatingLyricsColor = AppPreferences.floatingLyricsTextColor
    @State private var logText = ""
    @State private var showsLog = false
    @State private var glassTransparency = AppPreferences.floatingLyricsGlassTransparency
    @State private var editingGlassTransparency = false

    private var languagePackCheck: Int? {
        guard selection == .translation, actions.isWindowKey, translationProvider == .local, supportsTranslation else { return nil }
        return actions.languagePackRevision
    }

    var body: some View {
        let check = languagePackCheck
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Page.allCases) { page in
                    Button { selection = page } label: {
                        Label(page.rawValue, systemImage: page.icon)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selection == page ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == page ? .isSelected : [])
                }
                Spacer()
            }
            .padding(20)
            .padding(.top, 4)
            .frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(selection.rawValue).font(.largeTitle.weight(.bold)).padding(.horizontal, 20).padding(.top, 20)
                Form {
                    content
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
        .task(id: check) {
            guard check != nil, #available(macOS 15, *) else { return }
            installedSourceLanguages = nil
            let names = await LocalTranslationService.installedSourceLanguageNames()
            guard !Task.isCancelled else { return }
            installedSourceLanguages = names
        }
        .onChange(of: visible) { _ in changed() }
        .onChange(of: statusMode) { _ in changed() }
        .onChange(of: floatingMode) { _ in changed() }
        .onChange(of: floatingPositionLocked) { _ in actions.floatingPositionLockChanged?() }
        .onChange(of: floatingLyricsShadow) { _ in actions.floatingLyricsShadowChanged?() }
        .onChange(of: spaces) { _ in changed() }
        .onChange(of: fullScreen) { _ in changed() }
        .onChange(of: translation) { _ in changed() }
        .onChange(of: transliteration) { _ in changed() }
        .onChange(of: automaticTranslation) { _ in changed() }
        .onChange(of: translationProvider) { _ in changed() }
        .onChange(of: smooth) { _ in changed() }
        .onChange(of: gaps) { _ in changed() }
        .onChange(of: glassTransparency) { value in
            actions.previewGlassTransparency?(value)
            if !editingGlassTransparency { AppPreferences.floatingLyricsGlassTransparency = value }
        }
        .sheet(isPresented: $showsLog) {
            VStack(alignment: .trailing) {
                ScrollView { Text(logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("完成") { showsLog = false }.keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 650, height: 440)
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .menuBar:
            Section("显示") {
                Picker("显示模式", selection: $statusMode) {
                    Text("自动").tag(StatusBarMode.automatic)
                    Text("仅图标").tag(StatusBarMode.icon)
                }
                Text("自动模式根据屏幕选择歌词宽度，控制按钮位置固定。").font(.caption).foregroundStyle(.secondary)
                Text("桌面歌词打开时只显示三个播放键。按住 Option 点击播放键可打开播放器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("歌词颜色") {
                ColorPicker("高亮", selection: menuBarColor($activeColor) { AppPreferences.menuBarLyricsActiveColor = $0 })
                ColorPicker("未高亮", selection: menuBarColor($inactiveColor) { AppPreferences.menuBarLyricsInactiveColor = $0 })
                Button("恢复跟随系统") {
                    AppPreferences.resetMenuBarLyricsColors()
                    activeColor = Color(nsColor: AppPreferences.menuBarLyricsActiveColor)
                    inactiveColor = Color(nsColor: AppPreferences.menuBarLyricsInactiveColor)
                    changed()
                }
            }
        case .lyricEffects:
            Section("桌面歌词与菜单栏共用") {
                Toggle("平滑滚动", isOn: $smooth)
                Toggle("KTV 空档进度", isOn: $gaps)
            }
        case .translation:
            Section("桌面歌词显示") {
                Toggle("显示中文译文", isOn: $translation)
                Toggle("显示音译", isOn: $transliteration)
                Text("优先显示 Apple Music 缓存中的中文译文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自动翻译") {
                Picker("翻译方式", selection: $translationProvider) {
                    Text("系统本地").tag(TranslationProvider.local)
                    Text("联网大模型").tag(TranslationProvider.online)
                }
                Toggle("自动翻译外语歌词", isOn: $automaticTranslation)
                    .disabled(translationProvider == .local && !supportsTranslation)
                Text("翻译可能不准确，仅供参考。")
                    .font(.caption).foregroundStyle(.secondary)
                if supportsTranslation || translationProvider == .online {
                    LabeledContent("目标语言", value: "简体中文")
                    Text("在桌面歌词显示译文时运行。以中文为主的歌曲及中外文混合行保留原文。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("macOS 15 起支持本地自动翻译。当前系统可显示已有缓存译文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if translationProvider == .online {
                Section("翻译状态") {
                    Text(automaticTranslation ? actions.translationStatus : "自动翻译已关闭。尚未发起联网请求。")
                        .textSelection(.enabled)
                    if automaticTranslation {
                        Button("重试当前歌曲") { actions.retryOnlineTranslation?() }
                    }
                }
                OnlineTranslationSettings(onSaved: { actions.onlineTranslationConfigurationChanged?() })
            } else if supportsTranslation {
                Section("语言包") {
                    LabeledContent("已就绪") {
                        if let installedSourceLanguages {
                            Text(installedSourceLanguages.isEmpty
                                 ? "暂无可用的语言包" : installedSourceLanguages.joined(separator: "、"))
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("正在检查已下载的语言包…")
                        }
                    }
                    Text(automaticTranslation ? actions.translationStatus : "自动翻译已关闭")
                    Button("重新检查语言包") {
                        actions.languagePackRevision += 1
                        actions.retryLocalTranslation?()
                    }
                    Text("在「系统设置 → 通用 → 语言与地区 → 翻译语言」中下载所需语言。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .desktopLyrics:
            Section("窗口") {
                Toggle("显示桌面歌词", isOn: $visible)
                Picker("窗口模式", selection: $floatingMode) {
                    ForEach(FloatingLyricsMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented)
                if floatingMode == .vinyl {
                    Text("解锁后可拖动窗口边缘或角落调整大小。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("锁定位置并点击穿透", isOn: $floatingPositionLocked)
                if floatingPositionLocked {
                    Text("锁定时，左上角三个按钮和黑胶播放键仍可点击，其余区域会把点击传给后方窗口。点黄色锁即可解锁。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("外观") {
                Slider(value: Binding(
                    get: { fontScale },
                    set: { value in
                        fontScale = value
                        actions.previewFloatingLyricsFontSize(value)
                    }
                ), in: 0.8...1.3) {
                    Text("歌词字号")
                } onEditingChanged: { editing in
                    if !editing { actions.flushFloatingLyricsFontSize() }
                }
                ColorPicker("浮窗文字颜色", selection: Binding(
                    get: { floatingLyricsColor.map { Color(nsColor: $0) } ?? .primary },
                    set: { setFloatingLyricsColor(NSColor($0)) }
                ), supportsOpacity: false)
                Button("恢复跟随系统") { setFloatingLyricsColor(nil) }
                    .disabled(floatingLyricsColor == nil)
                HStack {
                    Slider(value: $glassTransparency, in: 0...1, step: 0.05) {
                        Text("玻璃透明度")
                    } onEditingChanged: { editing in
                        editingGlassTransparency = editing
                        if !editing { AppPreferences.floatingLyricsGlassTransparency = glassTransparency }
                    }
                    Text(glassTransparency, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary).accessibilityHidden(true)
                }.disabled(reduceTransparency)
                if reduceTransparency {
                    Text("系统已开启降低透明度。").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("浮窗阴影", isOn: $floatingLyricsShadow)
                Text("关闭可减少 GPU 合成开销，歌词和黑胶动画仍可正常播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("显示范围") {
                Picker("桌面范围", selection: $spaces) {
                    Text("所有桌面").tag("allSpaces")
                    Text("当前桌面").tag("currentDesktop")
                }
                Toggle("在全屏应用上方显示", isOn: $fullScreen)
            }
        case .maintenance:
            Section("歌词缓存") {
                Button("重新读取歌词缓存") { actions.refresh?() }
            }
            Section("软件更新") {
                Text(actions.updateStatus).foregroundStyle(.secondary)
                Button("检查更新") { actions.checkUpdates?() }
                    .disabled(actions.checkingUpdates || !UpdateService.isConfigured)
            }
            Section("诊断日志") {
                Button("查看日志…") { logText = DiagnosticLogger.shared.contents(); showsLog = true }
                Button("复制日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagnosticLogger.shared.contents(), forType: .string)
                }
                Button("在访达中显示") {
                    DiagnosticLogger.shared.prepareFile()
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLogger.shared.logFileURL])
                }
            }
        }
    }

    private var supportsTranslation: Bool { if #available(macOS 15, *) { return true }; return false }
    private func menuBarColor(_ selection: Binding<Color>, save: @escaping (NSColor) -> Void) -> Binding<Color> {
        Binding(get: { selection.wrappedValue }, set: { color in
            selection.wrappedValue = color
            save(NSColor(color))
            changed()
        })
    }

    private func setFloatingLyricsColor(_ color: NSColor?) {
        AppPreferences.floatingLyricsTextColor = color
        let savedColor = AppPreferences.floatingLyricsTextColor
        guard floatingLyricsColor != savedColor else { return }
        floatingLyricsColor = savedColor
        actions.floatingLyricsColorChanged?()
    }

    private func changed() { NotificationCenter.default.post(name: AppPreferences.didChange, object: nil) }
}
