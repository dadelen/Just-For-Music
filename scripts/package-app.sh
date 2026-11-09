#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/check-build-sdk.sh"

APP_NAME="Just-For-Music"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
HELPERS="$CONTENTS/Helpers"
ENTITLEMENTS="$ROOT/AppleMusicLyrics.entitlements"
APP_ICON="$ROOT/Resources/AppIcon.icns"
VERSION="${VERSION:-1.0.2}"
BUILD_NUMBER="${BUILD_NUMBER:-7}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-io.github.dadelen.just-for-music}"
UPDATE_REPOSITORY="${UPDATE_REPOSITORY-dadelen/Just-For-Music}"

if [[ ! "$BUNDLE_IDENTIFIER" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "BUNDLE_IDENTIFIER must be a reverse-DNS identifier" >&2
  exit 1
fi
if [[ -n "$UPDATE_REPOSITORY" && ! "$UPDATE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "UPDATE_REPOSITORY must be owner/repository" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must use numeric SemVer form, for example 1.2.3" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
if [[ ! -f "$APP_ICON" ]]; then
  echo "App icon not found: $APP_ICON" >&2
  exit 1
fi

BUILD_ARGS=(-c release --arch arm64)

echo "→ Building release binary…"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/AppleMusicLyrics"
HELPER_BIN="$BIN_DIR/AppleMusicLyricsPlaybackHelper"
if [[ ! -x "$BIN" ]]; then
  echo "Binary not found: $BIN" >&2
  exit 1
fi
if [[ ! -x "$HELPER_BIN" ]]; then
  echo "Helper binary not found: $HELPER_BIN" >&2
  exit 1
fi

for executable in "$BIN" "$HELPER_BIN"; do
  archs="$(lipo -archs "$executable")"
  if [[ "$archs" != "arm64" ]]; then
    echo "Expected an arm64 binary at $executable, found: $archs" >&2
    exit 1
  fi
done

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$HELPERS"
cp "$BIN" "$MACOS/$APP_NAME"
cp "$HELPER_BIN" "$HELPERS/AppleMusicLyricsPlaybackHelper"
cp "$APP_ICON" "$RESOURCES/AppIcon.icns"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/Resources/InstallGuide.txt" "$RESOURCES/InstallGuide.txt"
chmod +x "$MACOS/$APP_NAME" "$HELPERS/AppleMusicLyricsPlaybackHelper"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Just-For-Music</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.dadelen.just-for-music</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Just-For-Music</string>
  <key>CFBundleDisplayName</key>
  <string>Just-For-Music</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Just-For-Music reads the current track and controls playback in the Music app.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$CONTENTS/Info.plist"
if [[ -n "$UPDATE_REPOSITORY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :LyricsUpdateRepository string $UPDATE_REPOSITORY" "$CONTENTS/Info.plist"
fi

echo "→ Signing app with identity: $CODESIGN_IDENTITY"
/usr/bin/codesign \
  --force \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$CODESIGN_IDENTITY" \
  "$HELPERS/AppleMusicLyricsPlaybackHelper"
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$CODESIGN_IDENTITY" \
  "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "→ Done: $APP"
echo "  Open with: open \"$APP\""
