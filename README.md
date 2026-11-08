# Apple Music Lyrics · V2

English | [简体中文](README.zh-CN.md)

A local fork of [Takpap/apple-music-lyrics](https://github.com/Takpap/apple-music-lyrics).
The upstream MIT license, copyright and contributor attribution are preserved. This is an unofficial project, not affiliated with Apple.

The existing read-only Music cache provider, TTML parser and playback monitor remain the core. V2 adds:

- A single status item with scrolling original karaoke lyrics and three independent playback buttons.
- A compact player menu with real artwork, centered track details, transport, seek bar, Settings and Quit.
- An independent settings window with five categories.
- A system-glass floating panel: rotating vinyl on the left, original lyrics and smaller translations on the right. No custom background tint.
- Red, yellow and green controls close the panel, lock its position and choose Small, Large or Minimal. Minimal mode places the track details and playback controls above the lyrics.
- A softly lit vinyl record that turns once every six seconds and keeps its angle when paused. Click the tonearm to play or pause.
- Left-aligned lyrics emphasize the current line and soften nearby lines. Playback follow resumes four seconds after the last manual scroll.
- Three-dot gap progress driven by real playback time and confirmed lyric boundaries; unknown or sub-1.5-second gaps are not synthesized.
- Apple on-device translation, language identification, batching, caching and track-switch isolation. Existing Chinese cache translations take priority. Chinese and entire lines mixing Chinese with another language skip machine translation.
- Configurable GitHub Releases updates with SHA-256 verification. Updates are disabled when no repository is configured.

Removed: lyric exports, old floating layouts, click-through, Option-key interaction, global shortcuts and arbitrary resizing.

## Requirements

| Capability | Requirement |
| --- | --- |
| Architecture | Apple Silicon / arm64 only |
| Runtime | macOS 13+ |
| Glass | Native NSGlassEffectView on 26+; NSVisualEffectView on 13–25 |
| Machine translation | macOS 15+; older systems show cached translations only |
| Translation quality selection | macOS 26.4+; earlier systems use the available system strategy |
| Build SDK | Xcode 26.4+, macOS SDK 26.4+, Swift 6.3+ |

Reduce Transparency uses an opaque system background. Reduce Motion suppresses decorative vinyl rotation.
Translation strategy selection and fallback follow [Apple's documented behavior](https://developer.apple.com/documentation/translation/translationsession/strategy).

## Build and test

```bash
swift test
VERSION=2.1.0 ./scripts/package-app.sh
open "dist/Apple Music Lyrics.app"
```

The local preview bundle identifier is `local.applemusiclyrics.v2`, separate from upstream. Override it with `BUNDLE_IDENTIFIER` for your own build. The display name currently remains Apple Music Lyrics.

Allow Music automation when prompted. Open the lyrics panel in Music first to populate its cache. Install missing language resources through Settings → Translation; the app does not silently request downloads.

The app reads Music's private cache format at `~/Library/Caches/com.apple.Music/`. Format changes, cache eviction, unavailable lyrics and imported local tracks can prevent lyric retrieval. No account tokens are extracted. Lyrics are not sent to third-party translation services. Multi-character TTML spans use interpolated highlighting within their supplied timing.

Public APIs cannot precisely measure all remaining menu-bar space. Automatic mode chooses a conservative width; manual compact/icon modes remain available. The system can still hide a status item.

## Distribution

```bash
VERSION=2.1.0 ./scripts/create-release-artifacts.sh
```

This creates arm64 ZIP/DMG archives and SHA256SUMS in `dist/release/`. Local builds are ad-hoc signed and not notarized.

After creating your own repository, explicitly supply your own settings:

```bash
BUNDLE_IDENTIFIER=com.yourname.lyrics \
UPDATE_REPOSITORY=yourname/your-repository \
VERSION=2.1.0 ./scripts/create-release-artifacts.sh
```

No remote repository or Release was created during this development. Local builds have no update source by default. A future tag-triggered GitHub workflow uses its own `github.repository` as the update source; configure the repository variable `BUNDLE_IDENTIFIER` before publishing.

See [CONTRIBUTING.md](CONTRIBUTING.md) for integration tests and constraints, [requirements](docs/REQUIREMENTS_V2.md) and [delivery report](docs/DEVELOPMENT_REPORT.md) for verification status. Diagnostic logs may contain track metadata; review them before sharing.
