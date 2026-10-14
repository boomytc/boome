#!/bin/zsh
# Apple libtool in Xcode 27 drops Zig 0.15.2 objects that are not 8-byte
# aligned, so GhosttyKit's libghostty-fat.a is missing the terminal.
# Recombine the same static libraries with ar, which keeps those objects.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/vendor/ghostty/.zig-cache"
xc="$root/vendor/ghostty/macos/GhosttyKit.xcframework"
dest="$(find "$xc" -name 'libghostty*.a' -path '*macos*' | head -1)"
if [[ -z "$dest" ]]; then
  echo "no GhosttyKit static library to repack" >&2
  exit 1
fi

if nm -gU "$dest" 2>/dev/null | grep ' _ghostty_surface_new$' >/dev/null; then
  exit 0
fi

newest() {
  local name="$1"
  find "$cache" -name "$name" -type f -print0 |
    xargs -0 stat -f '%m %N' |
    sort -n |
    awk 'END { print $2 }'
}

ghostty=""
while IFS= read -r candidate; do
  [[ -z "$candidate" ]] && continue
  if nm -gU "$candidate" 2>/dev/null | grep ' _ghostty_surface_new$' >/dev/null; then
    ghostty="$candidate"
  fi
done < <(find "$cache" -name 'libghostty.a' -type f)
if [[ -z "$ghostty" ]]; then
  echo "libghostty.a with ghostty_surface_new was not in the Zig cache" >&2
  exit 1
fi

names=(
  libmacos.a
  libfreetype.a
  libpng.a
  libz.a
  liboniguruma.a
  libglslang.a
  libspirv_cross.a
  libsentry.a
  libbreakpad.a
  libhighway.a
  libsimdutf.a
  libutfcpp.a
  libintl.a
  libdcimgui.a
)

work="$(mktemp -d "$root/build/repack.XXXX")"
trap 'rm -rf "$work"' EXIT
out="$work/libghostty.a"
index=0
add_archive() {
  local archive="$1"
  local dir="$work/p$index"
  mkdir -p "$dir"
  (cd "$dir" && ar -x "$archive")
  chmod 644 "$dir"/* 2>/dev/null || true
  local objects=()
  local object_path base
  for object_path in "$dir"/*; do
    [[ -f "$object_path" ]] || continue
    base="${object_path:t}"
    case "$base" in
      __.SYMDEF*) continue ;;
    esac
    local renamed="$dir/${index}_${base}"
    mv "$object_path" "$renamed"
    objects+=("$renamed")
  done
  if [[ ${#objects[@]} -eq 0 ]]; then
    index=$((index + 1))
    return
  fi
  if [[ ! -f "$out" ]]; then
    ar -qc "$out" "${objects[@]}"
  else
    ar -q "$out" "${objects[@]}" >/dev/null
  fi
  index=$((index + 1))
}

add_archive "$ghostty"
for name in "${names[@]}"; do
  archive="$(newest "$name" || true)"
  if [[ -z "$archive" ]]; then
    echo "missing $name in $cache" >&2
    exit 1
  fi
  add_archive "$archive"
done
ranlib "$out"
if ! nm -gU "$out" | grep ' _ghostty_surface_new$' >/dev/null; then
  echo "repacked archive still has no ghostty_surface_new" >&2
  exit 1
fi
install -m 644 "$out" "$dest"
echo "repacked $dest"
