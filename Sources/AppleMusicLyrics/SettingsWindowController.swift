import AppKit
import SwiftUI

final class SettingsActions: ObservableObject {
    @Published var updateStatus = "更新源待配置"
    @Published var translationStatus = "等待歌词"
    @Published var checkingUpdates = false
    var refresh: (() -> Void)?
    var checkUpdates: (() -> Void)?
    var prepareTranslation: (() -> Void)?
}

final class SettingsWindowController {
    let actions = SettingsActions()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Apple Music Lyrics 设置"
            window.titlebarAppearsTransparent = true
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
    @ObservedObject var actions: SettingsActions
    @State private var selection = "常规"
    @AppStorage("floatingLyrics.visible") private var visible = true
    @AppStorage("statusBar.mode") private var statusMode = "automatic"
    @AppStorage("floatingLyrics.size") private var size = "small"
    @AppStorage("floatingLyrics.opacity") private var opacity = 0.92
    @AppStorage("floatingLyrics.spaceBehavior") private var spaces = "allSpaces"
    @AppStorage("floatingLyrics.showOverFullScreen") private var fullScreen = true
    @AppStorage("floatingLyrics.showTranslation") private var translation = true
    @AppStorage("floatingLyrics.showTransliteration") private var transliteration = true
    @AppStorage("translation.enabled") private var automaticTranslation = true
    @AppStorage("translation.highQuality") private var highQuality = true
    @AppStorage("lyrics.smoothScrolling") private var smooth = true
    @AppStorage("lyrics.gapAnimation") private var gaps = true
    @AppStorage("lyrics.fontScale") private var fontScale = 1.0
    @State private var activeColor = Color(nsColor: AppPreferences.menuBarLyricsActiveColor)
    @State private var inactiveColor = Color(nsColor: AppPreferences.menuBarLyricsInactiveColor)
    @State private var logText = ""
    @State private var showsLog = false

    private let categories = ["常规", "歌词", "翻译", "悬浮窗口", "更新与诊断"]
    private let icons = ["slider.horizontal.3", "text.quote", "character.bubble", "macwindow", "arrow.down.circle"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LYRICS").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary).padding(.bottom, 16)
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    Button { selection = category } label: {
                        Label(category, systemImage: icons[index])
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selection == category ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Apple Silicon\nmacOS 原生歌词").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(selection).font(.largeTitle.weight(.bold)).padding(.horizontal, 20).padding(.top, 20)
                Form {
                    content
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
        .onChange(of: visible) { _ in changed() }
        .onChange(of: statusMode) { _ in changed() }
        .onChange(of: size) { _ in changed() }
        .onChange(of: opacity) { _ in changed() }
        .onChange(of: spaces) { _ in changed() }
        .onChange(of: fullScreen) { _ in changed() }
        .onChange(of: translation) { _ in changed() }
        .onChange(of: transliteration) { _ in changed() }
        .onChange(of: automaticTranslation) { _ in changed() }
        .onChange(of: highQuality) { _ in changed() }
        .onChange(of: smooth) { _ in changed() }
        .onChange(of: gaps) { _ in changed() }
        .onChange(of: fontScale) { _ in changed() }
        .onChange(of: activeColor) { value in
            AppPreferences.menuBarLyricsActiveColor = NSColor(value)
            changed()
        }
        .onChange(of: inactiveColor) { value in
            AppPreferences.menuBarLyricsInactiveColor = NSColor(value)
            changed()
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
        case "常规":
            Section {
                Toggle("显示桌面歌词", isOn: $visible)
                Picker("状态栏显示", selection: $statusMode) {
                    Text("自动").tag("automatic")
                    Text("完整").tag("full")
                    Text("紧凑").tag("compact")
                    Text("仅图标").tag("icon")
                }
                Text("自动模式根据屏幕选择歌词宽度，控制按钮位置固定。").font(.caption).foregroundStyle(.secondary)
            }
        case "歌词":
            Section("状态栏颜色") {
                ColorPicker("高亮", selection: $activeColor)
                ColorPicker("未高亮", selection: $inactiveColor)
                Button("恢复默认颜色") {
                    AppPreferences.resetMenuBarLyricsColors()
                    activeColor = Color(nsColor: AppPreferences.menuBarLyricsActiveColor)
                    inactiveColor = Color(nsColor: AppPreferences.menuBarLyricsInactiveColor)
                    changed()
                }
            }
            Section("显示") {
                Slider(value: $fontScale, in: 0.8...1.3) { Text("浮窗字号") }
                Toggle("平滑滚动", isOn: $smooth)
                Toggle("KTV 空档进度", isOn: $gaps)
                Button("重新读取歌词缓存") { actions.refresh?() }
            }
        case "翻译":
            Section {
                Toggle("自动翻译外语歌词", isOn: $automaticTranslation).disabled(!supportsTranslation)
                LabeledContent("目标语言", value: "简体中文")
                Toggle("优先高质量翻译", isOn: $highQuality).disabled(!supportsQuality)
                Text("中文及中外文混合的歌词行保留原文。优先显示 Apple Music 已有中文译文。").font(.caption).foregroundStyle(.secondary)
            }
            Section("本地语言资源") {
                Text(supportsTranslation ? actions.translationStatus : "macOS 15 起支持本地自动翻译，当前显示缓存译文。")
                Button("准备语言资源…") { actions.prepareTranslation?() }.disabled(!supportsTranslation)
                Text("语言资源由系统管理，首次下载会请求确认。").font(.caption).foregroundStyle(.secondary)
            }
        case "悬浮窗口":
            Section {
                Picker("窗口尺寸", selection: $size) {
                    Text("Small").tag("small")
                    Text("Large").tag("large")
                }.pickerStyle(.segmented)
                Toggle("显示桌面歌词", isOn: $visible)
                Toggle("显示译文", isOn: $translation)
                Toggle("显示音译", isOn: $transliteration)
            }
            Section("材质与桌面") {
                if #available(macOS 26.0, *) {
                    Text("原生 Liquid Glass，透明效果随系统和背景调整。").font(.callout).foregroundStyle(.secondary)
                } else {
                    Slider(value: $opacity, in: 0.35...1) { Text("背景透明度") }
                }
                Picker("桌面范围", selection: $spaces) {
                    Text("所有桌面").tag("allSpaces")
                    Text("当前桌面").tag("currentDesktop")
                }
                Toggle("在全屏应用上方显示", isOn: $fullScreen)
            }
        default:
            Section("软件更新") {
                Text(actions.updateStatus).foregroundStyle(.secondary)
                Button(actions.checkingUpdates ? "正在检查…" : "检查更新…") { actions.checkUpdates?() }
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
    private var supportsQuality: Bool { if #available(macOS 26.4, *) { return true }; return false }
    private func changed() { NotificationCenter.default.post(name: AppPreferences.didChange, object: nil) }
}
