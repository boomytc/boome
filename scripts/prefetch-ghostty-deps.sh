#!/bin/zsh
# Zig 0.15.2's HTTP client gets 400 from deps.files.ghostty.org.
# curl can download the same URLs. `zig fetch` on the file fills the
# global cache with the hash build.zig.zon already names, so `zig build`
# does not ask the network for that package again.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
zig="${ZIG:-$HOME/.local/zig/zig-aarch64-macos-0.15.2/zig}"
cache="${BOOME_DEP_CACHE:-$HOME/.cache/boome/ghostty-deps}"
mkdir -p "$cache"

if [[ ! -x "$zig" ]]; then
  echo "zig not found at $zig" >&2
  exit 1
fi

# Top-level and pkg/*/build.zig.zon. Zig 0.15.2 fetches these while loading
# the build graph, including lazy packages the macOS library still touches.
python3 - "$root/vendor/ghostty" <<'PY' | while IFS=$'\t' read -r url hash; do
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
seen = set()
for zon in root.rglob("build.zig.zon"):
    if any(part in {".zig-cache", "zig-out", "zig-cache"} for part in zon.parts):
        continue
    text = zon.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(
        r'\.url = "(https://[^"]+)"\s*,\s*\n\s*\.hash = "([^"]+)"',
        text,
    ):
        key = (match.group(1), match.group(2))
        if key in seen:
            continue
        seen.add(key)
        print(match.group(1) + "\t" + match.group(2))
PY
  name="$(basename "$url")"
  file="$cache/$name"
  if [[ ! -s "$file" ]]; then
    echo "download $name"
    curl -fL --retry 3 -o "$file.partial" "$url"
    mv "$file.partial" "$file"
  fi
  got="$("$zig" fetch "$file")"
  if [[ "$got" != "$hash" ]]; then
    echo "hash mismatch for $name" >&2
    echo "  zon:  $hash" >&2
    echo "  file: $got" >&2
    exit 1
  fi
  echo "cached $hash"
done
