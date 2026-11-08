import AppKit
import Foundation

enum FloatingLyricsSpaceBehavior: String, CaseIterable {
    case currentDesktop
    case allSpaces

    var title: String {
        switch self {
        case .currentDesktop: return "Current Desktop"
        case .allSpaces: return "All Desktops"
        }
    }
}

enum FloatingLyricsSize: String, CaseIterable {
    case small, large, minimal

    var title: String {
        switch self {
        case .small: return "Small"
        case .large: return "Large"
        case .minimal: return "极简"
        }
    }

    var dimensions: NSSize {
        switch self {
        case .small: return NSSize(width: 640, height: 260)
        case .large: return NSSize(width: 880, height: 380)
        case .minimal: return NSSize(width: 440, height: 300)
        }
    }
}

enum StatusBarMode: String, CaseIterable {
    case automatic, full, compact, icon
}

enum AppPreferences {
    static let didChange = Notification.Name("LyricsPreferencesChanged")
    static var floatingSize: FloatingLyricsSize {
        get { enumValue("floatingLyrics.size", default: .small) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "floatingLyrics.size") }
    }
    static var floatingPositionLocked: Bool {
        get { UserDefaults.standard.bool(forKey: "floatingLyrics.positionLocked") }
        set { UserDefaults.standard.set(newValue, forKey: "floatingLyrics.positionLocked") }
    }
    static var statusBarMode: StatusBarMode {
        get { enumValue("statusBar.mode", default: .automatic) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "statusBar.mode") }
    }
    static var smoothScrolling: Bool {
        get { defaultedBool("lyrics.smoothScrolling", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.smoothScrolling") }
    }
    static var gapAnimation: Bool {
        get { defaultedBool("lyrics.gapAnimation", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.gapAnimation") }
    }
    static var fontScale: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "lyrics.fontScale")
            return value == 0 ? 1 : min(1.3, max(0.8, value))
        }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.fontScale") }
    }
    static var automaticTranslation: Bool {
        get { defaultedBool("translation.enabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "translation.enabled") }
    }
    static var highQualityTranslation: Bool {
        get { defaultedBool("translation.highQuality", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "translation.highQuality") }
    }
    static let translationTarget = "zh-Hans"

    static func migrate() {
        for key in ["floatingLyrics.locked", "floatingLyrics.clickThrough", "floatingLyrics.mode",
                    "floatingLyrics.blurStrength", "floatingLyrics.immersiveHeight",
                    "export.includeTranslation", "export.includeTransliteration"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private enum Key {
        static let floatingVisible = "floatingLyrics.visible"
        static let opacity = "floatingLyrics.opacity"
        static let spaceBehavior = "floatingLyrics.spaceBehavior"
        static let showOverFullScreen = "floatingLyrics.showOverFullScreen"
        static let showTranslation = "floatingLyrics.showTranslation"
        static let showTransliteration = "floatingLyrics.showTransliteration"
        static let framesByDisplay = "floatingLyrics.framesByDisplay"
        static let lastDisplay = "floatingLyrics.lastDisplay"
        static let menuBarActiveColor = "menuBarLyrics.activeColor"
        static let menuBarInactiveColor = "menuBarLyrics.inactiveColor"
        static let lastUpdateCheck = "updates.lastCheck"
        static let lastNotifiedVersion = "updates.lastNotifiedVersion"
    }

    static let defaultMenuBarLyricsActiveColor = NSColor.labelColor.withAlphaComponent(0.96)
    static let defaultMenuBarLyricsInactiveColor = NSColor.labelColor.withAlphaComponent(0.42)

    static var floatingLyricsVisible: Bool {
        get { defaultedBool(Key.floatingVisible, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.floatingVisible) }
    }

    static var floatingLyricsOpacity: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.opacity) != nil else { return 0.92 }
            return min(1, max(0.35, UserDefaults.standard.double(forKey: Key.opacity)))
        }
        set { UserDefaults.standard.set(min(1, max(0.35, newValue)), forKey: Key.opacity) }
    }

    static var floatingLyricsSpaceBehavior: FloatingLyricsSpaceBehavior {
        get { enumValue(Key.spaceBehavior, default: .allSpaces) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.spaceBehavior) }
    }

    static var floatingLyricsShowOverFullScreen: Bool {
        get { defaultedBool(Key.showOverFullScreen, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showOverFullScreen) }
    }

    static var floatingLyricsShowTranslation: Bool {
        get { defaultedBool(Key.showTranslation, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTranslation) }
    }

    static var floatingLyricsShowTransliteration: Bool {
        get { defaultedBool(Key.showTransliteration, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTransliteration) }
    }

    static var floatingLyricsFramesByDisplay: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Key.framesByDisplay) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Key.framesByDisplay) }
    }

    static var floatingLyricsLastDisplay: String? {
        get { UserDefaults.standard.string(forKey: Key.lastDisplay) }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastDisplay) }
    }

    static var menuBarLyricsActiveColor: NSColor {
        get { color(Key.menuBarActiveColor, default: defaultMenuBarLyricsActiveColor) }
        set { setColor(newValue, forKey: Key.menuBarActiveColor) }
    }

    static var menuBarLyricsInactiveColor: NSColor {
        get { color(Key.menuBarInactiveColor, default: defaultMenuBarLyricsInactiveColor) }
        set { setColor(newValue, forKey: Key.menuBarInactiveColor) }
    }

    static func resetMenuBarLyricsColors() {
        [Key.menuBarActiveColor, Key.menuBarInactiveColor]
            .forEach(UserDefaults.standard.removeObject(forKey:))
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: Key.lastUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    static var lastNotifiedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.lastNotifiedVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastNotifiedVersion) }
    }

    private static func defaultedBool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? value
            : UserDefaults.standard.bool(forKey: key)
    }

    private static func enumValue<T: RawRepresentable>(
        _ key: String,
        default value: T
    ) -> T where T.RawValue == String {
        guard let rawValue = UserDefaults.standard.string(forKey: key),
              let result = T(rawValue: rawValue) else { return value }
        return result
    }

    private static func color(_ key: String, default defaultColor: NSColor) -> NSColor {
        storedColor(key) ?? defaultColor
    }

    private static func storedColor(_ key: String) -> NSColor? {
        guard let stored = UserDefaults.standard.array(forKey: key), stored.count == 4 else {
            return nil
        }
        let components = stored.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard components.count == 4,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(components[0]),
            green: CGFloat(components[1]),
            blue: CGFloat(components[2]),
            alpha: CGFloat(components[3])
        )
    }

    private static func setColor(_ color: NSColor, forKey key: String) {
        guard let color = color.usingColorSpace(.sRGB) else { return }
        let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map(Double.init)
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        UserDefaults.standard.set(components, forKey: key)
    }
}
