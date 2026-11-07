# Contributing

Thanks for contributing to Apple Music Lyrics.

## Development Setup

Requirements:

- Apple silicon Mac running macOS 13 or later
- Xcode 26.4 or later with macOS SDK 26.4+ (Swift 6.3+); deployment remains macOS 13
- Music.app for integration testing

Build and test before opening a pull request:

```bash
swift build
swift test
```

To validate the private Music.app cache integration, start a catalog track whose
lyrics have already appeared in Music.app, then run:

```bash
APPLE_MUSIC_CACHE_INTEGRATION=1 \
  swift test --filter AppleMusicCacheIntegrationTests
```

To check local translation using **already installed** system resources on macOS 26+:

```bash
LOCAL_TRANSLATION_INTEGRATION=1 swift test --filter LocalTranslationIntegrationTests
```

This test uses synthetic text, never requests language downloads, and skips if resources are missing.
The regular suite includes deterministic language, cache, gap-boundary and vinyl-timing tests.

## Pull Requests

- Keep changes focused and consistent with the existing AppKit architecture.
- Add or update tests for TTML parsing, cache matching, and timing behavior.
- Preserve read-only access to Music.app's cache.
- Do not add account-token extraction, request interception, or hidden network calls.
- Preserve the `com.apple.security.automation.apple-events` entitlement when
  packaging with Hardened Runtime; without it, Music automation is denied
  before macOS can show the permission prompt.
- Do not commit `.build`, `dist`, app bundles, local cache data, or copyrighted lyrics.
- Document behavior that depends on a private Apple format.
- For V2 automatic translation, skip any lyric line that mixes Chinese and
  another language. Fully foreign-language lines in the same song can still
  qualify for translation.

## Test Fixtures

Use short, synthetic text in fixtures. Do not copy production lyrics or cache
responses into the repository. Reduce reported cache samples to the smallest
structure necessary to reproduce a parser or matching issue.

## Releases

Configure the repository variable `BUNDLE_IDENTIFIER` with your own reverse-DNS identifier.
The workflow embeds `github.repository` as its update source; local builds leave updates disabled
unless `UPDATE_REPOSITORY=owner/repository` is explicitly supplied. The local preview identifier
is `local.applemusiclyrics.v2`, different from upstream. Never publish without configuring your own identity.

Maintainers publish releases with annotated tags in `vMAJOR.MINOR.PATCH` form.
The tag workflow runs tests and uploads arm64 ZIP and DMG artifacts. Do not
manually commit generated files from `dist/`.
