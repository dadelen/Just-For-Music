#!/usr/bin/env bash
set -euo pipefail
# Deployment remains macOS 13. The newer SDK supplies gated Translation APIs.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
SDK_REMAINDER="${SDK_VERSION#*.}"
SDK_MINOR="${SDK_REMAINDER%%.*}"
if (( SDK_MAJOR < 26 || (SDK_MAJOR == 26 && SDK_MINOR < 4) )); then
  echo "Build requires the macOS 26.4+ SDK (Xcode 26.4+); found $SDK_VERSION." >&2
  exit 1
fi
