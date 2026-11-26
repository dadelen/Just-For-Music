import Foundation
import XCTest
@testable import AppleMusicLyrics

final class PlaybackSourcePreferenceTests: XCTestCase {
    @MainActor
    func testSettingsSelectionPersistsBeforeNotifyingAndIgnoresRepeatedSelection() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.playbackSourceKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.removeObject(forKey: key)

        let settings = SettingsWindowController()
        var changes: [PlaybackSource] = []
        settings.actions.playbackSourceChanged = { source in
            XCTAssertEqual(AppPreferences.playbackSource, source)
            changes.append(source)
        }

        settings.actions.selectPlaybackSource(.appleMusic)
        XCTAssertTrue(changes.isEmpty)
        settings.actions.selectPlaybackSource(.netease)
        XCTAssertEqual(defaults.string(forKey: key), PlaybackSource.netease.rawValue)
        settings.actions.selectPlaybackSource(.netease)
        settings.actions.selectPlaybackSource(.appleMusic)
        XCTAssertEqual(changes, [.netease, .appleMusic])
        XCTAssertEqual(defaults.string(forKey: key), PlaybackSource.appleMusic.rawValue)
    }

    func testNewAndExistingInstallationsDefaultToAppleMusicAndRememberSelection() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.playbackSourceKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertEqual(AppPreferences.playbackSource, .appleMusic)
        defaults.set("unknown", forKey: key)
        XCTAssertEqual(AppPreferences.playbackSource, .appleMusic)
        for source in PlaybackSource.allCases {
            AppPreferences.playbackSource = source
            XCTAssertEqual(defaults.string(forKey: key), source.rawValue)
            XCTAssertEqual(AppPreferences.playbackSource, source)
        }
    }
}
