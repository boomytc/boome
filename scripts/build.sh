#!/bin/zsh
# Build GhosttyKit from the pinned submodule, then Boome.app.
# One heavy Zig compile at a time. Swift rebuilds skip Zig when the
# xcframework is already present unless --rebuild-lib is passed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
zig="${ZIG:-$HOME/.local/zig/zig-aarch64-macos-0.15.2/zig}"
expected_zig="0.15.2"
shim="${BOOME_SDK_SHIM:-$HOME/.cache/boome/MacOSX-arm64-shim.sdk}"
jobs="${BOOME_ZIG_JOBS:-4}"
app="$root/build/Boome.app"
rebuild_lib=0
if [[ "${1:-}" == "--rebuild-lib" ]]; then
  rebuild_lib=1
fi

if [[ ! -x "$zig" ]]; then
  echo "Zig $expected_zig is not installed at $zig" >&2
  echo "Ghostty v1.3.1 requires this version. Do not substitute another Zig." >&2
  echo "Download: https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz" >&2
  exit 1
fi
got="$("$zig" version)"
if [[ "$got" != "$expected_zig" ]]; then
  echo "Zig $got does not match minimum_zig_version $expected_zig. Stop." >&2
  exit 1
fi

if pgrep -f 'zig build' >/dev/null 2>&1; then
  echo "A zig build is already running. This machine builds one heavy target at a time." >&2
  exit 1
fi

export BOOME_SDK_SHIM="$shim"
python3 "$root/scripts/macos-sdk-shim.py" >/dev/null
chmod +x "$root/scripts/xcrun-shim/xcrun" "$root/scripts/prefetch-ghostty-deps.sh"
export PATH="$root/scripts/xcrun-shim:$PATH"
hash -r

xc="$root/vendor/ghostty/macos/GhosttyKit.xcframework"
if [[ "$rebuild_lib" == 1 || ! -d "$xc" ]]; then
  ZIG="$zig" "$root/scripts/prefetch-ghostty-deps.sh"
  log="$root/build/zig-build.log"
  mkdir -p "$root/build"
  cd "$root/vendor/ghostty"
  # v1.3.1 has no -Demit-lib-vt. libghostty-vt is attached to the default
  # install step, so this command still compiles it and does not link it.
  # -Dxcframework-target=native keeps the framework to this Mac's slice.
  # emit-macos-app defaults to true when emit-xcframework is true, so the
  # false value has to be explicit or Zig also builds Ghostty.app.
  attempt=0
  while true; do
    set +e
    "$zig" build \
      -Doptimize=ReleaseFast \
      -Demit-xcframework=true \
      -Demit-macos-app=false \
      -Dxcframework-target=native \
      -j"$jobs" \
      >"$log" 2>&1
    zig_status=$?
    set -e
    if [[ $zig_status -eq 0 ]]; then
      break
    fi
    urls="$(grep -oE 'https://[^" ]+' "$log" | sort -u || true)"
    if [[ -z "$urls" || $attempt -ge 12 ]]; then
      echo "zig build failed (exit $zig_status). Log: $log" >&2
      tail -40 "$log" >&2
      exit "$zig_status"
    fi
    attempt=$((attempt + 1))
    echo "zig fetch returned HTTP 400; caching the URL with curl and retrying ($attempt)" >&2
    cache="${BOOME_DEP_CACHE:-$HOME/.cache/boome/ghostty-deps}"
    mkdir -p "$cache"
    while IFS= read -r url; do
      [[ -z "$url" ]] && continue
      name="$(basename "$url")"
      file="$cache/$name"
      if [[ ! -s "$file" ]]; then
        curl -fL --retry 3 -o "$file.partial" "$url"
        mv "$file.partial" "$file"
      fi
      "$zig" fetch "$file" >/dev/null
    done <<<"$urls"
  done
fi

chmod +x "$root/scripts/repack-libghostty.sh"
"$root/scripts/repack-libghostty.sh"

lib="$(find "$xc" -name 'libghostty*.a' -path '*macos*' | head -1)"
headers="$(find "$xc" -type d -name Headers | head -1)"
if [[ -z "$lib" || -z "$headers" ]]; then
  echo "GhosttyKit.xcframework is missing a macOS static library or headers" >&2
  find "$xc" -maxdepth 3 -type d -o -name '*.a' >&2 || true
  exit 1
fi

share="$root/vendor/ghostty/zig-out/share"
terminfo_sentinel="$share/terminfo/78/xterm-ghostty"
shell_dir="$share/ghostty/shell-integration"
if [[ ! -e "$terminfo_sentinel" ]]; then
  echo "Missing $terminfo_sentinel" >&2
  echo "Shells will not get TERM=xterm-ghostty. Refusing to skip this." >&2
  exit 1
fi
if [[ ! -d "$shell_dir" ]]; then
  echo "Missing $shell_dir" >&2
  echo "Shell integration will not load. Refusing to skip this." >&2
  exit 1
fi

install_app_icon() {
  local root="$1"
  local app="$2"
  local png="$root/resources/AppIcon.png"
  local iconset="$root/build/AppIcon.iconset"
  if [[ ! -f "$png" ]]; then
    echo "Missing $png" >&2
    exit 1
  fi
  rm -rf "$iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$png" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$png" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$png" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$png" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$png" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$png" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$png" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$png" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$png" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$png" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
  cp "$png" "$app/Contents/Resources/AppIcon.png"
}

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/src/Info.plist" "$app/Contents/Info.plist"
# Same layout as Ghostty's macOS bundle: Resources/ghostty next to
# Resources/terminfo, plus the other share/ trees (completions, man, themes).
cp -R "$share"/. "$app/Contents/Resources/"
install_app_icon "$root" "$app"

# swiftc uses Apple's linker, which understands the real SDK. The xcrun
# wrapper above would hand it the shim; call the real xcrun for the app link.
real_sdk="$(PATH=/usr/bin:/bin /usr/bin/xcrun --sdk macosx --show-sdk-path)"

swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -sdk "$real_sdk" \
  -I "$headers" \
  -Xcc "-fmodule-map-file=$headers/module.modulemap" \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework Carbon \
  -framework CoreText \
  -framework CoreGraphics \
  -framework CoreVideo \
  -framework QuartzCore \
  -framework IOSurface \
  -framework IOKit \
  -framework CoreFoundation \
  -framework Foundation \
  -framework CoreServices \
  -framework Security \
  -framework CFNetwork \
  -framework UniformTypeIdentifiers \
  -framework GameController \
  -lc++ \
  -Xlinker -force_load -Xlinker "$lib" \
  -o "$app/Contents/MacOS/Boome" \
  "$root/src/AppDelegate.swift" \
  "$root/src/BoomeChrome.swift" \
  "$root/src/TabLogic.swift" \
  "$root/src/ProjectTree.swift" \
  "$root/src/ProjectTextFile.swift" \
  "$root/src/ProjectExplorerView.swift" \
  "$root/src/FileEditorView.swift" \
  "$root/src/GhosttyHost.swift" \
  "$root/src/TerminalSurfaceView.swift" \
  "$root/src/MainWindowController.swift"

echo "$app"
