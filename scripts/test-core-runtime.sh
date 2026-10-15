#!/bin/zsh
# Real libghostty/AppKit checks, not physical mouse or cross-display validation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/build.sh"
app="$root/build/BoomeCoreRuntimeTests.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R "$root/build/core/share"/. "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.boom.boome.core-runtime-tests</string>
<key>CFBundleExecutable</key><string>BoomeCoreRuntimeTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
sdk="$(PATH=/usr/bin:/bin /usr/bin/xcrun --sdk macosx --show-sdk-path)"
headers="$root/build/core/include"
sources=("$root"/src/*.swift)
sources=("${(@)sources:#*/AppDelegate.swift}")
frameworks=(AppKit Metal MetalKit Carbon CoreText CoreGraphics CoreVideo QuartzCore IOSurface IOKit CoreFoundation Foundation CoreServices Security CFNetwork UniformTypeIdentifiers GameController)
args=()
for framework in "${frameworks[@]}"; do args+=(-framework "$framework"); done
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos13.0 \
  -sdk "$sdk" -I "$headers" -Xcc "-fmodule-map-file=$headers/module.modulemap" \
  "${args[@]}" -lc++ -Xlinker -force_load -Xlinker "$root/build/core/lib/libghostty.a" \
  "${sources[@]}" "$root/tests/CoreRuntimeTests.swift" \
  -o "$app/Contents/MacOS/BoomeCoreRuntimeTests"
# Isolated config and HOME prevent user shell profiles from entering the fixture.
home="$(mktemp -d "${TMPDIR:-/tmp}/boome-core-runtime-home.XXXXXX")"
trap 'rm -rf "$home"' EXIT
HOME="$home" ZDOTDIR="$home" XDG_CONFIG_HOME="$home/config" \
  "$app/Contents/MacOS/BoomeCoreRuntimeTests" \
  --config-default-files=false --command=/bin/zsh
