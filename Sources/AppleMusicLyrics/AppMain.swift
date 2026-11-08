import AppKit

#if !arch(arm64)
#error("Just-For-Music requires Apple silicon (arm64).")
#endif

enum AppIdentity {
    static let name = "Just-For-Music"
    static let bundleIdentifier = "io.github.dadelen.just-for-music"
}

@main
enum AppleMusicLyricsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        app.run()
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
