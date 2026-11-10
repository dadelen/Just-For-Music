# Just-For-Music

English | [简体中文](README.zh-CN.md)


## 🎬 Demo

https://github.com/user-attachments/assets/425befea-16e8-4ab0-81e0-11004ee798d1



A macOS menu bar companion for Apple Music with synced lyrics, playback controls, and a floating lyrics window. [Download for Apple Silicon](https://github.com/dadelen/Just-For-Music/releases/latest) · [Changelog](CHANGELOG.md)

The existing read-only Music cache provider, TTML parser and playback monitor remain the core.

- Automatic and Icon Only status bar modes. Automatic shows scrolling original karaoke lyrics and three native status bar playback buttons.
- While floating lyrics are visible, only the three playback buttons appear in the status bar. Option-click a playback button to open the player panel.
- A rounded player panel with real artwork, track details and a seek bar. Its text buttons open Lyrics and Settings or quit the app.
- An independent settings window for Desktop Lyrics, Menu Bar, Lyric Effects, Translation, and Maintenance.
- A system-glass floating panel: rotating vinyl on the left, original lyrics and smaller translations on the right. No custom background tint.
- Red, yellow and green controls close the panel, lock its position and choose Vinyl or Minimal. Drag the unlocked Vinyl panel's edges or corners to resize it between 640 × 260 and 880 × 380 pt. Minimal mode places the track details and playback controls above the lyrics.
- When locked, the window buttons and tonearm control stay interactive while the rest of the panel passes clicks through. Click the yellow button to unlock.
- A softly lit vinyl record that turns once every 12 beats, or every six seconds when BPM is unavailable. The record keeps its angle when paused. Click the tonearm to play or pause.
- Left-aligned lyrics emphasize the current line and soften nearby lines. Playback follow resumes four seconds after the last manual scroll.
- Three-dot gap progress driven by real playback time and confirmed lyric boundaries; unknown or sub-1.5-second gaps are not synthesized.
- Apple on-device translation, with batching, caching and track-switch isolation. The app checks the lyrics' language tag first and identifies untagged songs on-device. Only clearly foreign-language songs qualify for automatic translation. Existing Chinese cache translations take priority.
- GitHub Releases updates from this repository, with SHA-256 verification for installer downloads.

Removed: lyric exports, old floating layouts, Option-key interaction and global shortcuts.

## Requirements

| Capability | Requirement |
| --- | --- |
| Architecture | Apple Silicon / arm64 only |
| Runtime | macOS 13+ |
| Glass | Native NSGlassEffectView on 26+; NSVisualEffectView on 13–25 |
| Machine translation | System on-device translation on macOS 15+ |
| Automatic translation | Off by default. The default provider is system on-device translation. |
| Build SDK | Xcode 26.4+, macOS SDK 26.4+, Swift 6.3+ |

Reduce Transparency uses an opaque system background. Reduce Motion suppresses decorative vinyl rotation.

## Build and test

```bash
swift test
./scripts/package-app.sh
open "dist/Just-For-Music.app"
```

The default bundle identifier is `io.github.dadelen.just-for-music`.

Allow Music automation when prompted. Open the lyrics panel in Music first to populate its cache. Local translation uses installed system language packs. Download any missing packs in System Settings → General → Language & Region → Translation Languages, then recheck in the app’s Translation settings.

Online model translation is temporarily disabled. Saved configurations are retained.

The app reads Music's private cache format at `~/Library/Caches/com.apple.Music/`. Format changes, cache eviction, unavailable lyrics and imported local tracks can prevent lyric retrieval. No account tokens are extracted. Multi-character TTML spans use interpolated highlighting within their supplied timing.

Automatic mode chooses a conservative width, and Icon Only mode is available when space is limited. The system can still hide a status item.

## Distribution

```bash
VERSION=1.0.3 BUILD_NUMBER=10 ./scripts/create-release-artifacts.sh
```

This creates arm64 ZIP/DMG archives and SHA256SUMS in `dist/release/`. Local builds are ad-hoc signed and not notarized.

Forks can override the defaults:

```bash
BUNDLE_IDENTIFIER=com.yourname.lyrics \
UPDATE_REPOSITORY=yourname/your-repository \
VERSION=1.0.3 BUILD_NUMBER=10 ./scripts/create-release-artifacts.sh
```

The `v1.0` release contains source archives. Three-part version tags can trigger the installer build workflow. It uses the repository that runs the workflow as the update source.

See [CONTRIBUTING.md](CONTRIBUTING.md) for integration tests and constraints, [requirements](docs/REQUIREMENTS_V2.md) and [delivery report](docs/DEVELOPMENT_REPORT.md) for verification status. Diagnostic logs may contain track metadata; review them before sharing.

## Attribution and notices

Maintained by [dadelen](https://github.com/dadelen). Based on [Takpap/apple-music-lyrics](https://github.com/Takpap/apple-music-lyrics), with thanks to Takpap and the original contributors. The original copyright notice and [MIT License](LICENSE) are retained.

Just-For-Music is an independent project. Apple does not sponsor or endorse it. Apple, Apple Music, and macOS are trademarks of Apple Inc. Lyrics, artwork, and other Music content belong to their respective rights holders. The project's MIT license applies to the software.
