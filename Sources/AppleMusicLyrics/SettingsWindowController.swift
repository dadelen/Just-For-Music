import AppKit
import ApplicationServices
import Security
import SwiftUI

@MainActor
final class SettingsActions: ObservableObject {
    @Published var updateStatus = "更新源待配置"
    @Published var translationStatus = "等待歌词"
    @Published var languagePackRevision = 0
    @Published var floatingLyricsSizeRevision = 0
    @Published var isWindowKey = false
    @Published var checkingUpdates = false
    @Published private(set) var netEaseAccessibilityAccess = false
    @Published private(set) var appleMusicAutomationAccess = false
    @Published private(set) var appleMusicAutomationRequested =
        UserDefaults.standard.string(forKey: SettingsActions.automationRequestKey) == SettingsActions.installationIdentity
    @Published var requestingAppleMusicAutomation = false
    @Published var appleMusicCacheAccess: AppleMusicCacheLyricsProvider.CacheAccess = .missing
    var playbackSourceChanged: ((PlaybackSource) -> Void)?
    var authorizeAppleMusic: (() -> Void)?
    var refreshAppleMusicCacheAccess: (() -> Void)?
    var refresh: (() -> Void)?
    var checkUpdates: (() -> Void)?
    var retryLocalTranslation: (() -> Void)?
    var onlineTranslationConfigurationChanged: (() -> Void)?
    var retryOnlineTranslation: (() -> Void)?
    var floatingLyricsColorChanged: (() -> Void)?
    var floatingLyricsFontSizeChanged: (() -> Void)?
    var floatingLyricsSize: ((FloatingLyricsMode) -> (size: NSSize, minimum: NSSize, maximum: NSSize))?
    var floatingLyricsSizeChanged: ((FloatingLyricsMode, NSSize) -> Void)?
    var previewGlassTransparency: ((Double) -> Void)?
    var floatingLyricsShadowChanged: (() -> Void)?
    var floatingPositionLockChanged: (() -> Void)?
    private var pendingFontScale: Double?
    private var fontSizePreviewTimer: Timer?
    private static let automationRequestKey = "permissions.appleMusicAutomationRequestedInstallation"
    private static let installationIdentity: String = {
        var code: SecStaticCode?
        var signingInfo: CFDictionary?
        if SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
           let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
           let hash = (signingInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return hash.base64EncodedString()
        }
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "")/\(info?["CFBundleVersion"] as? String ?? "")"
    }()

    func selectPlaybackSource(_ source: PlaybackSource) {
        guard source != AppPreferences.playbackSource else { return }
        AppPreferences.playbackSource = source
        playbackSourceChanged?(source)
        checkPlaybackPermissions()
    }

    func checkPlaybackPermissions() {
        if AppPreferences.playbackSource == .appleMusic {
            let granted = PlaybackMonitor.hasMusicAutomationAccess()
            if appleMusicAutomationAccess != granted { appleMusicAutomationAccess = granted }
            refreshAppleMusicCacheAccess?()
        } else {
            checkNetEaseAccessibility()
        }
    }

    func recordAppleMusicAutomationRequest() {
        UserDefaults.standard.set(Self.installationIdentity, forKey: Self.automationRequestKey)
        appleMusicAutomationRequested = true
    }

    func checkNetEaseAccessibility() {
        guard AppPreferences.playbackSource == .netease else { return }
        let axGranted = AXIsProcessTrusted()
        if netEaseAccessibilityAccess != axGranted { netEaseAccessibilityAccess = axGranted }
    }

    func requestNetEaseAccessibilityAccess() {
        guard AppPreferences.playbackSource == .netease else { return }
        netEaseAccessibilityAccess = NetEasePlayback.requestAccessibilityAccess()
    }

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
    func windowDidBecomeKey(_ notification: Notification) {
        // Keep the controls reachable when the lyrics panel is expanded over Settings.
        window?.level = .floating
        actions.isWindowKey = true
        actions.checkPlaybackPermissions()
    }
    func windowDidResignKey(_ notification: Notification) {
        window?.level = .normal
        actions.isWindowKey = false
    }
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
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.delegate = self
            window.title = "\(AppIdentity.name) 设置"
            window.backgroundColor = .windowBackgroundColor
            window.contentMinSize = NSSize(width: 650, height: 450)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(actions: actions))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case playback = "播放来源"
        case desktopLyrics = "桌面歌词"
        case menuBar = "菜单栏"
        case lyricEffects = "歌词效果"
        case translation = "翻译"
        case maintenance = "维护"

        var id: Self { self }

        var icon: String {
            switch self {
            case .playback: return "headphones"
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
    @State private var selection: Page = .playback
    @AppStorage(AppPreferences.playbackSourceKey) private var playbackSource: PlaybackSource = .appleMusic
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
    private var usesOnlineTranslation: Bool { AppPreferences.onlineTranslationAvailable && translationProvider == .online }
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
        guard selection == .translation, actions.isWindowKey, !usesOnlineTranslation, supportsTranslation else { return nil }
        return actions.languagePackRevision
    }

    var body: some View {
        let check = languagePackCheck
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.rawValue)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                Form {
                    content(for: selection)
                }
                .formStyle(.grouped)
                .toggleStyle(.switch)
                .scrollContentBackground(.hidden)
                .id(selection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .font(.system(size: 14))
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
                ScrollView { Text(logText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("完成") { showsLog = false }.keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 650, height: 440)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Page.allCases) { page in
                let selected = selection == page
                Button { selection = page } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.icon)
                            .frame(width: 20)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        Text(page.rawValue)
                            .fontWeight(selected ? .semibold : .medium)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(selected ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(width: 172)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func content(for page: Page) -> some View {
        switch page {
        case .playback:
            Section {
                PlaybackSourcePicker(selection: playbackSource, onSelect: actions.selectPlaybackSource)
                    .padding(.vertical, 4)
                if playbackSource == .appleMusic {
                    note("从本地缓存读取。缺歌词时，在「音乐」打开歌词面板。")
                } else {
                    note("跟随网易云客户端的播放进度，按曲目获取歌词。")
                }
            }
            if playbackSource == .appleMusic {
                appleMusicPermissions
            } else {
                netEasePermissions
            }
        case .menuBar:
            Section("显示") {
                Picker("显示模式", selection: $statusMode) {
                    Text("自动").tag(StatusBarMode.automatic)
                    Text("仅图标").tag(StatusBarMode.icon)
                }
                note("自动模式按屏幕空间调整歌词宽度。桌面歌词打开时，菜单栏仅保留播放键。")
                note("按住 Option 点击播放键，可打开播放器。")
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
                note("优先显示歌曲已有的中文译文。")
            }
            Section("自动翻译") {
                if AppPreferences.onlineTranslationAvailable {
                    Picker("翻译方式", selection: $translationProvider) {
                        Text("系统本地").tag(TranslationProvider.local)
                        Text("联网大模型").tag(TranslationProvider.online)
                    }
                }
                Toggle("自动翻译外语歌词", isOn: $automaticTranslation)
                    .disabled(!usesOnlineTranslation && !supportsTranslation)
                if supportsTranslation || usesOnlineTranslation {
                    LabeledContent("目标语言", value: "简体中文")
                    note("桌面歌词开启译文后运行。以中文为主的歌曲及中外文混合行保留原文。")
                } else {
                    note("本地自动翻译需要 macOS 15。已有译文仍可显示。")
                }
            }
            if usesOnlineTranslation {
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
                    note("可在「系统设置 → 通用 → 语言与地区 → 翻译语言」下载语言包。")
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
                Toggle("锁定位置并点击穿透", isOn: $floatingPositionLocked)
                if floatingPositionLocked {
                    note("锁定时仍可用窗口按钮和播放键。点黄色锁解锁。")
                }
            }
            floatingLyricsSizeSection
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
                    note("系统已开启降低透明度。")
                }
                Toggle("浮窗阴影", isOn: $floatingLyricsShadow)
            }
            Section("显示范围") {
                Picker("桌面范围", selection: $spaces) {
                    Text("所有桌面").tag("allSpaces")
                    Text("当前桌面").tag("currentDesktop")
                }
                Toggle("在全屏应用上方显示", isOn: $fullScreen)
            }
        case .maintenance:
            Section("歌词") {
                Button(playbackSource == .appleMusic ? "重新读取歌词缓存" : "重新获取当前歌词") { actions.refresh?() }
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

    @ViewBuilder private var appleMusicPermissions: some View {
        Section("Apple Music 权限") {
            if actions.appleMusicAutomationAccess {
                Text("已允许读取和控制音乐播放")
            } else if actions.appleMusicAutomationRequested {
                if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    Link("打开自动化权限设置", destination: settings)
                }
            } else {
                Button("允许控制音乐…") { actions.authorizeAppleMusic?() }
                    .disabled(actions.requestingAppleMusicAutomation)
            }
            if actions.appleMusicCacheAccess == .denied {
                note("macOS 拒绝读取音乐的本地歌词缓存。请在「隐私与安全性 → 媒体与 Apple Music」中允许 \(AppIdentity.name)。")
                if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    Link("打开隐私与安全性设置", destination: settings)
                }
            }
        }
    }

    @ViewBuilder private var netEasePermissions: some View {
        Section("辅助功能") {
            if actions.netEaseAccessibilityAccess {
                Text("辅助功能权限已开启").foregroundStyle(.secondary)
            } else {
                note("旧版网易云需要辅助功能权限才能通过菜单控制播放。")
                Button("请求辅助功能权限…") { actions.requestNetEaseAccessibilityAccess() }
                if let permissions = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    Link("打开辅助功能权限设置", destination: permissions)
                }
            }
        }
        .onAppear { actions.checkNetEaseAccessibility() }
    }

    @ViewBuilder private var floatingLyricsSizeSection: some View {
        let mode = floatingMode
        if let dimensions = actions.floatingLyricsSize?(mode) {
            Section("卡片大小") {
                dimensionSlider("宽度", for: \.width, mode: mode, dimensions: dimensions)
                dimensionSlider("高度", for: \.height, mode: mode, dimensions: dimensions)
                note(floatingPositionLocked ? "歌词字号随卡片大小调整。"
                     : "歌词字号随卡片大小调整，也可拖动浮窗边缘或角落。")
            }
        }
    }

    @ViewBuilder private func dimensionSlider(
        _ title: String,
        for dimension: WritableKeyPath<NSSize, CGFloat>,
        mode: FloatingLyricsMode,
        dimensions: (size: NSSize, minimum: NSSize, maximum: NSSize)
    ) -> some View {
        let current = Double(dimensions.size[keyPath: dimension])
        let minimum = Double(dimensions.minimum[keyPath: dimension])
        let maximum = Double(dimensions.maximum[keyPath: dimension])
        if minimum < maximum, let resize = actions.floatingLyricsSizeChanged {
            let value = Binding<Double>(
                get: {
                    let size = actions.floatingLyricsSize?(mode).size ?? dimensions.size
                    return min(max(Double(size[keyPath: dimension]), minimum), maximum)
                },
                set: { newValue in
                    guard var size = actions.floatingLyricsSize?(mode).size else { return }
                    size[keyPath: dimension] = CGFloat(newValue)
                    resize(mode, size)
                }
            )
            LabeledContent {
                HStack(spacing: 12) {
                    Slider(value: value, in: minimum...maximum) { Text(title) }
                        .labelsHidden()
                        .accessibilityLabel(title)
                        .accessibilityValue(dimensionValue(value.wrappedValue))
                    Text(dimensionValue(value.wrappedValue))
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .frame(minWidth: 170, idealWidth: 225, maxWidth: 280)
            } label: {
                Text(title)
            }
        } else {
            LabeledContent(title, value: dimensionValue(current))
        }
    }

    private func dimensionValue(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) 点"
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
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

private struct PlaybackSourcePicker: View {
    let selection: PlaybackSource
    var onSelect: (PlaybackSource) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { options }
            VStack(spacing: 10) { options }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放来源")
    }

    private var options: some View {
        ForEach(PlaybackSource.allCases, id: \.self) { source in
            let selected = selection == source
            Button { onSelect(source) } label: {
                HStack(spacing: 9) {
                    Image(systemName: source == .appleMusic ? "music.note" : "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 33, height: 33)
                        .background(source == .appleMusic ? Color.indigo : Color.red,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    Text(source.title)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 3)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.11),
                                      lineWidth: selected ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}
