#!/bin/zsh
# Build Boome's checked-in terminal core, then Boome.app.
# One heavy Zig compile at a time. Content fingerprints reuse unchanged
# core builds; --rebuild-lib forces the Zig build.
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
  echo "Boome's terminal core requires this version. Do not substitute another Zig." >&2
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

# All core sources are owned by this repository. No upstream checkout,
# patch application, xcframework, or cache-wide archive search is needed.
mkdir -p "$root/build"
core="$root/core"
out="$root/build/core"
lib="$out/lib/libghostty.a"
headers="$out/include"
share="$out/share"
stamp="$out/.source-fingerprint"
real_sdk="$(PATH=/usr/bin:/bin /usr/bin/xcrun --sdk macosx --show-sdk-path)"
sdk_build="$(PATH=/usr/bin:/bin /usr/bin/xcrun --sdk macosx --show-sdk-build-version)"

core_fingerprint() {
  python3 "$root/scripts/core-fingerprint.py" "$core" \
    --metadata "$zig|$got|$real_sdk|$sdk_build|$shim|ReleaseFast|aarch64-macos" \
    --file "$root/scripts/build.sh" \
    --file "$root/scripts/core-fingerprint.py" \
    --file "$root/scripts/macos-sdk-shim.py" \
    --file "$root/scripts/xcrun-shim/xcrun" \
    --file "$root/scripts/prefetch-ghostty-deps.sh"
}

fingerprint="$(core_fingerprint)"
cached_fingerprint=""
if [[ -f "$stamp" ]]; then cached_fingerprint="$(<"$stamp")"; fi
built_core=0
if [[ "$rebuild_lib" == 1 || ! -f "$lib" || ! -f "$headers/ghostty.h" ||
      ! -f "$headers/module.modulemap" || ! -f "$stamp" ||
      ! -e "$share/terminfo/78/xterm-ghostty" ||
      ! -d "$share/ghostty/shell-integration" ||
      "$cached_fingerprint" != "$fingerprint" ]]; then
  ZIG="$zig" "$root/scripts/prefetch-ghostty-deps.sh"
  # Remove only our generated install prefix, never core sources.
  rm -rf "$out"
  log="$root/build/zig-build.log"
  attempt=0
  while true; do
    set +e
    (cd "$core" && "$zig" build \
      -Doptimize=ReleaseFast \
      --prefix "$out" \
      --cache-dir "$root/build/zig-cache" \
      -j"$jobs") >"$log" 2>&1
    zig_status=$?
    set -e
    if [[ $zig_status -eq 0 ]]; then
      built_core=1
      break
    fi
    urls="$(grep -oE 'https://[^" ]+' "$log" | sort -u || true)"
    if [[ -z "$urls" || $attempt -ge 12 ]]; then
      echo "terminal core build failed (exit $zig_status). Log: $log" >&2
      tail -40 "$log" >&2
      exit "$zig_status"
    fi
    attempt=$((attempt + 1))
    echo "Caching missing Zig dependencies with curl and retrying ($attempt)" >&2
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
else
  echo "Terminal core unchanged; reusing $lib"
fi

if [[ ! -f "$headers/ghostty.h" || ! -f "$headers/module.modulemap" ||
      ! -f "$lib" ]] ||
   ! nm -gU "$lib" 2>/dev/null | grep ' _ghostty_surface_new$' >/dev/null; then
  echo "Terminal core is missing its headers or ghostty_surface_new" >&2
  exit 1
fi

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

if [[ "$built_core" == 1 ]]; then
  if [[ "$(core_fingerprint)" != "$fingerprint" ]]; then
    echo "Core inputs changed during compilation; rebuild before linking Boome." >&2
    exit 1
  fi
  printf '%s\n' "$fingerprint" > "$stamp.tmp"
  mv "$stamp.tmp" "$stamp"
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

# Swift links the installed core with Apple's linker and the real SDK,
# not the SDK shim that only Zig's build runner needs.

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
  "$root/src/SessionArrangement.swift" \
  "$root/src/SessionDragViews.swift" \
  "$root/src/TabSidebar.swift" \
  "$root/src/SessionWindowManager.swift" \
  "$root/src/ProjectTree.swift" \
  "$root/src/ProjectTextFile.swift" \
  "$root/src/ProjectExplorerView.swift" \
  "$root/src/FileEditorView.swift" \
  "$root/src/GhosttyHost.swift" \
  "$root/src/TerminalSurfaceView.swift" \
  "$root/src/MainWindowController.swift"

echo "$app"
