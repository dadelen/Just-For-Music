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

enum FloatingLyricsMode: String, CaseIterable {
    case vinyl, minimal

    static let minimumVinylSize = NSSize(width: 640, height: 260)
    static let maximumVinylSize = NSSize(width: 880, height: 380)
    static let minimalSize = NSSize(width: 440, height: 300)

    var title: String {
        switch self {
        case .vinyl: return "黑胶"
        case .minimal: return "极简"
        }
    }

    static func clampedVinylSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: size.width.isFinite ? max(minimumVinylSize.width, size.width) : minimumVinylSize.width,
            height: size.height.isFinite ? max(minimumVinylSize.height, size.height) : minimumVinylSize.height
        )
    }
}

enum StatusBarMode: String {
    case automatic, icon
}

enum TranslationProvider: String {
    case local, online
}

struct OnlineTranslationProfiles: Codable {
    struct Profile: Codable, Identifiable {
        let id: UUID
        var configuration: OnlineTranslationConfiguration
    }

    var entries: [Profile] = []
    var activeID: UUID?

    var activeConfiguration: OnlineTranslationConfiguration? {
        entries.first { $0.id == activeID }?.configuration
    }

    mutating func save(_ profile: Profile) {
        if let index = entries.firstIndex(where: { $0.id == profile.id }) {
            entries[index] = profile
        } else {
            entries.append(profile)
        }
        if entries.count == 1 { activeID = profile.id }
    }

    mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
}

enum AppPreferences {
    static let didChange = Notification.Name("LyricsPreferencesChanged")
    static let statusBarModeKey = "statusBar.mode"
    static let automaticTranslationKey = "translation.enabled"
    static let translationProviderKey = "translation.provider"
    static let onlineTranslationAvailable = false
    static var translationProvider: TranslationProvider {
        onlineTranslationAvailable ? enumValue(translationProviderKey, default: .local) : .local
    }
    static var onlineTranslationProfiles: OnlineTranslationProfiles {
        get {
            guard let data = UserDefaults.standard.data(forKey: "translation.online.profiles"),
                  let profiles = try? JSONDecoder().decode(OnlineTranslationProfiles.self, from: data)
            else { return OnlineTranslationProfiles() }
            return profiles
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "translation.online.profiles")
        }
    }
    static let floatingLyricsModeKey = "floatingLyrics.size"
    static let floatingPositionLockKey = "floatingLyrics.positionLocked"
    static let floatingLyricsShadowKey = "floatingLyrics.showWindowShadow"
    static var floatingLyricsShowsShadow: Bool {
        defaultedBool(floatingLyricsShadowKey, default: true)
    }
    static var floatingLyricsMode: FloatingLyricsMode {
        get { enumValue(floatingLyricsModeKey, default: .vinyl) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: floatingLyricsModeKey) }
    }
    static var floatingLyricsVinylSize: NSSize {
        get {
            if let stored = UserDefaults.standard.string(forKey: Key.vinylSize) {
                return FloatingLyricsMode.clampedVinylSize(NSSizeFromString(stored))
            }
            // The floating controller is created before the launch migration.
            return UserDefaults.standard.string(forKey: floatingLyricsModeKey) == "large"
                ? FloatingLyricsMode.maximumVinylSize : FloatingLyricsMode.minimumVinylSize
        }
        set {
            let value = NSStringFromSize(FloatingLyricsMode.clampedVinylSize(newValue))
            if value != UserDefaults.standard.string(forKey: Key.vinylSize) {
                UserDefaults.standard.set(value, forKey: Key.vinylSize)
            }
        }
    }
    static var floatingPositionLocked: Bool {
        get { UserDefaults.standard.bool(forKey: floatingPositionLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: floatingPositionLockKey) }
    }
    static var statusBarMode: StatusBarMode {
        get { enumValue(statusBarModeKey, default: .automatic) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: statusBarModeKey) }
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
        get { UserDefaults.standard.bool(forKey: automaticTranslationKey) }
        set { UserDefaults.standard.set(newValue, forKey: automaticTranslationKey) }
    }
    static let translationTarget = "zh-Hans"

    static func migrate() {
        if UserDefaults.standard.object(forKey: "translation.online.profiles") == nil,
           let data = UserDefaults.standard.data(forKey: "translation.online.configuration"),
           let configuration = try? JSONDecoder().decode(OnlineTranslationConfiguration.self, from: data) {
            let id = UUID()
            onlineTranslationProfiles = OnlineTranslationProfiles(entries: [.init(id: id, configuration: configuration)], activeID: id)
        }
        if let stored = UserDefaults.standard.string(forKey: statusBarModeKey), StatusBarMode(rawValue: stored) == nil {
            statusBarMode = .automatic
        }
        if let stored = UserDefaults.standard.string(forKey: floatingLyricsModeKey),
           stored == "small" || stored == "large" {
            let legacySize = floatingLyricsVinylSize
            floatingLyricsVinylSize = legacySize
            floatingLyricsMode = .vinyl
        }
        for key in ["floatingLyrics.locked", "floatingLyrics.clickThrough", "floatingLyrics.mode",
                    "floatingLyrics.blurStrength", "floatingLyrics.immersiveHeight",
                    "export.includeTranslation", "export.includeTransliteration"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private enum Key {
        static let floatingVisible = "floatingLyrics.visible"
        static let spaceBehavior = "floatingLyrics.spaceBehavior"
        static let showOverFullScreen = "floatingLyrics.showOverFullScreen"
        static let textColor = "floatingLyrics.textColor"
        static let showTranslation = "floatingLyrics.showTranslation"
        static let showTransliteration = "floatingLyrics.showTransliteration"
        static let glassTransparency = "floatingLyrics.glassTransparency"
        static let vinylSize = "floatingLyrics.vinylSize"
        static let framesByDisplay = "floatingLyrics.framesByDisplay"
        static let lastDisplay = "floatingLyrics.lastDisplay"
        static let menuBarActiveColor = "menuBarLyrics.activeColor"
        static let menuBarInactiveColor = "menuBarLyrics.inactiveColor"
        static let lastUpdateCheck = "updates.lastCheck"
        static let lastNotifiedVersion = "updates.lastNotifiedVersion"
    }

    static let defaultMenuBarLyricsActiveColor = NSColor.labelColor
    static let defaultMenuBarLyricsInactiveColor = NSColor.secondaryLabelColor

    static var floatingLyricsVisible: Bool {
        get { defaultedBool(Key.floatingVisible, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.floatingVisible) }
    }

    static var floatingLyricsSpaceBehavior: FloatingLyricsSpaceBehavior {
        get { enumValue(Key.spaceBehavior, default: .allSpaces) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.spaceBehavior) }
    }

    static var floatingLyricsShowOverFullScreen: Bool {
        get { defaultedBool(Key.showOverFullScreen, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showOverFullScreen) }
    }

    static var floatingLyricsTextColor: NSColor? {
        get { storedColor(Key.textColor) }
        set {
            if let newValue {
                setColor(newValue.withAlphaComponent(1), forKey: Key.textColor)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.textColor)
            }
        }
    }

    static var floatingLyricsShowTranslation: Bool {
        get { defaultedBool(Key.showTranslation, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTranslation) }
    }

    static var floatingLyricsShowTransliteration: Bool {
        get { defaultedBool(Key.showTransliteration, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTransliteration) }
    }

    static var floatingLyricsGlassTransparency: Double {
        get {
            let value = UserDefaults.standard.double(forKey: Key.glassTransparency)
            return value.isFinite ? min(1, max(0, value)) : 0
        }
        set {
            guard newValue.isFinite else { return }
            let value = min(1, max(0, newValue))
            if value != floatingLyricsGlassTransparency {
                UserDefaults.standard.set(value, forKey: Key.glassTransparency)
            }
        }
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
