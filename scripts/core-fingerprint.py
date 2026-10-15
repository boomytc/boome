#!/usr/bin/env python3
"""Content fingerprint for Boome's checked-in terminal core and its toolchain."""

import argparse
import hashlib
from pathlib import Path
import stat

IGNORED = {".zig-cache", "zig-out", "__pycache__", ".DS_Store"}


def fingerprint(core: Path, metadata: list[str], extra_files: list[Path]) -> str:
    if core.is_symlink() or not core.is_dir():
        raise ValueError(f"terminal core must be a real source directory: {core}")
    digest = hashlib.sha256(b"boome-terminal-core-v1\0")

    def add(label: str, path: Path) -> None:
        if path.is_symlink():
            raise ValueError(f"source symlinks are not supported: {path}")
        digest.update(label.encode("utf-8") + b"\0")
        info = path.stat()
        digest.update(f"{info.st_size}:{stat.S_IMODE(info.st_mode)}\0".encode("ascii"))
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)

    for path in sorted(core.rglob("*")):
        relative = path.relative_to(core)
        if any(part in IGNORED for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError(f"source symlinks are not supported: {path}")
        if path.is_file():
            add(relative.as_posix(), path)
    for index, value in enumerate(metadata):
        digest.update(f"metadata:{index}\0{value}\0".encode("utf-8"))
    for index, path in enumerate(extra_files):
        add(f"extra:{index}", path)
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("--metadata", action="append", default=[])
    parser.add_argument("--file", type=Path, action="append", default=[])
    args = parser.parse_args()
    print(fingerprint(args.core, args.metadata, args.file))
