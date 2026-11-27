import AppKit

#if !arch(arm64)
#error("VerseMotion requires Apple silicon (arm64).")
#endif

enum AppIdentity {
    static let name = "VerseMotion"
    // Keep the executable name stable so 1.2.0 and newer builds can hand off.
    static let executableName = "Just-For-Music"
    static let bundleIdentifier = "io.github.dadelen.just-for-music"
}

@main
enum AppleMusicLyricsApp {
    private static let handoffKey = "JFMSupportsInstanceHandoff"

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard takeOverFromOlderCopies() else { return }

        // LSUIElement apps are visible through runningApplications, without
        // posting NSWorkspace did-launch notifications.
        let observer = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { workspace, change in
            for launched in change.newValue ?? workspace.runningApplications where isOtherCopy(launched) {
                guard let bundleURL = launched.bundleURL,
                      Bundle(url: bundleURL)?.object(forInfoDictionaryKey: handoffKey) as? Bool != true else { continue }
                launched.terminate()
            }
        }
        defer { observer.invalidate() }

        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        app.run()
    }

    private static func takeOverFromOlderCopies() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter(isOtherCopy)
        guard !others.isEmpty else { return true }
        guard !others.contains(where: { launchedLater($0, than: current) }) else { return false }

        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return others.allSatisfy(\.isTerminated)
    }

    private static func isOtherCopy(_ app: NSRunningApplication) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == identifier && !app.isTerminated
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && app.executableURL?.lastPathComponent == AppIdentity.executableName
    }

    private static func launchedLater(_ app: NSRunningApplication, than other: NSRunningApplication) -> Bool {
        if let date = app.launchDate, let otherDate = other.launchDate, date != otherDate {
            return date > otherDate
        }
        return app.processIdentifier > other.processIdentifier
    }

    private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: AppIdentity.name)
        menu.addItem(application)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        return menu
    }
}
