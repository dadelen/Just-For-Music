import AppKit

#if !arch(arm64)
#error("Apple Music Lyrics requires Apple silicon (arm64).")
#endif

@main
enum AppleMusicLyricsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
