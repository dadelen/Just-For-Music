#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/check-build-sdk.sh"

echo "→ Building Just-For-Music…"
BUILD_ARGS=(-c release --arch arm64)
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/AppleMusicLyrics"
echo "→ Launching $BIN"
echo "  First run: allow Automation access for Music when prompted."
echo "  Quit from the menu bar item, or: pkill -f AppleMusicLyrics"
exec "$BIN"
