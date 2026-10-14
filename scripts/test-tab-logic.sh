#!/bin/zsh
# Run the tab-list, presentation, close-policy, and shortcut decisions.
# Same Swift toolchain as scripts/build.sh. Does not link libghostty.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(PATH=/usr/bin:/bin /usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$root/build"
out="$root/build/tab-logic-tests"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -sdk "$sdk" \
  -framework AppKit \
  -o "$out" \
  "$root/src/TabLogic.swift" \
  "$root/src/BoomeChrome.swift" \
  "$root/tests/TabLogicTests.swift"

"$out"
