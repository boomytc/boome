#!/bin/zsh
# Run tab decisions, project-tree fixtures, panel layout, and embedded-editor checks.
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
  "$root/src/SessionArrangement.swift" \
  "$root/src/SessionDragViews.swift" \
  "$root/src/TabSidebar.swift" \
  "$root/tests/SessionArrangementTests.swift" \
  "$root/src/BoomeChrome.swift" \
  "$root/src/ProjectTree.swift" \
  "$root/src/ProjectTextFile.swift" \
  "$root/src/ProjectExplorerView.swift" \
  "$root/src/FileEditorView.swift" \
  "$root/src/CommandInputProtocol.swift" \
  "$root/src/CommandInputView.swift" \
  "$root/tests/ProjectExplorerTests.swift" \
  "$root/tests/CommandInputTests.swift" \
  "$root/tests/TabLogicTests.swift"

"$out"
