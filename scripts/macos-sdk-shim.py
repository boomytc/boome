#!/usr/bin/env python3
"""Build a macOS SDK copy Zig 0.15.2 can link.

macOS 27's text-based stubs list arm64e-macos and not arm64-macos.
Zig 0.15.2 treats those as different targets, so every link fails with
undefined libSystem symbols. Zig 0.16 matches them; this tag of Ghostty
rejects any other Zig. The shim copies the installed SDK (APFS clone when
it can) and adds an arm64-* target next to each arm64e-* target. It does
not modify the Xcode SDK.
"""

import os
import re
import shutil
import subprocess
import sys

STAMP_NAME = ".boome-arm64-shim-v2"
ARM64E = re.compile(r"(?<![\w.])arm64e-([A-Za-z0-9-]+)")


def sdk_source() -> str:
    out = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    return os.path.realpath(out)


def destination() -> str:
    root = os.environ.get("BOOME_SDK_SHIM")
    if root:
        return root
    return os.path.expanduser("~/.cache/boome/MacOSX-arm64-shim.sdk")


def patch_text(text: str) -> str:
    """Add arm64-<os> beside each arm64e-<os> that does not already have it.

    Some stubs already list arm64-macos in a later export block. A file-level
    "already present" check would leave the top-level targets line as
    arm64e-only, which is the line Zig 0.15.2 uses.
    """

    def repl(match: re.Match[str]) -> str:
        arm64e = match.group(0)
        plain = "arm64-" + match.group(1)
        prefix = text[max(0, match.start() - len(plain) - 2) : match.start()]
        if prefix.endswith(plain + ", ") or prefix.endswith(plain + ","):
            return arm64e
        return plain + ", " + arm64e

    return ARM64E.sub(repl, text)


def clone_sdk(src: str, dest: str) -> None:
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    if os.path.lexists(dest):
        shutil.rmtree(dest)
    # -c is APFS clonefile. Fall back to a normal copy.
    result = subprocess.run(["cp", "-cR", src, dest])
    if result.returncode != 0:
        shutil.copytree(src, dest, symlinks=True)


def patch_tree(dest: str) -> int:
    changed = 0
    for dirpath, dirnames, filenames in os.walk(dest, followlinks=False):
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
        for name in filenames:
            if not name.endswith(".tbd"):
                continue
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
                original = handle.read()
            updated = patch_text(original)
            if updated == original:
                continue
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write(updated)
            changed += 1
    return changed


def patch_math_h(dest: str) -> None:
    """macOS 27 math.h skips INFINITY when the compiler advertises modules.

    Zig 0.15.2's bundled libc++ includes math.h and uses the macro. The
    compiler reports module support but does not load Apple's module, so
    the macro has to be present in this SDK copy.
    """
    path = os.path.join(dest, "usr", "include", "math.h")
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        text = handle.read()
    old = (
        "#if !defined(__GNUC__) || !defined(__has_feature) || !__has_feature(modules) "
        "|| !defined(__has_include) || !__has_include(<float.h>)\n"
        "#define INFINITY    HUGE_VALF\n"
        "#endif\n"
    )
    new = "#ifndef INFINITY\n#define INFINITY    HUGE_VALF\n#endif\n"
    if old not in text:
        if new not in text:
            raise SystemExit(f"math.h INFINITY guard not found in {path}")
        return
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(text.replace(old, new, 1))


def main() -> int:
    src = sdk_source()
    dest = destination()
    stamp = os.path.join(dest, STAMP_NAME)
    marker = src + "\n"
    if os.path.isdir(dest) and not os.path.islink(dest) and os.path.exists(stamp):
        with open(stamp, "r", encoding="utf-8") as handle:
            if handle.read() == marker:
                print(dest)
                return 0
    if not (os.path.isdir(dest) and not os.path.islink(dest)):
        print(f"cloning {src}", file=sys.stderr)
        clone_sdk(src, dest)
    print("patching tbd targets", file=sys.stderr)
    changed = patch_tree(dest)
    patch_math_h(dest)
    probe = os.path.join(dest, "usr", "lib", "libSystem.B.tbd")
    with open(probe, "r", encoding="utf-8", errors="surrogateescape") as handle:
        body = handle.read(800)
    header = body.split("targets:", 1)[-1][:180]
    if "arm64-macos" not in header:
        print("shim failed: libSystem.B.tbd has no arm64-macos", file=sys.stderr)
        return 1
    with open(stamp, "w", encoding="utf-8") as handle:
        handle.write(marker)
    print(f"patched {changed} tbd files", file=sys.stderr)
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
