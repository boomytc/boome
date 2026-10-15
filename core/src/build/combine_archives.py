#!/usr/bin/env python3
"""Combine precisely the archives supplied by Zig, without searching its cache."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def combine(zig: Path, output: Path, archives: list[Path]) -> None:
    if not archives:
        raise ValueError("at least one archive is required")
    zig = zig.resolve(strict=True)
    archives = [path.resolve(strict=True) for path in archives]
    output = output.resolve()
    if output in archives:
        raise ValueError("output must not overwrite an input archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".combine-", dir=output.parent) as directory:
        work = Path(directory)
        lines = ["CREATE combined.a"]
        for index, archive in enumerate(archives):
            # MRI gets safe relative names, even for source paths containing spaces.
            name = f"input-{index}.a"
            (work / name).symlink_to(archive)
            lines.append(f"ADDLIB {name}")
        lines.extend(["SAVE", "END", ""])
        subprocess.run(
            [str(zig), "ar", "--format=darwin", "-M"],
            input="\n".join(lines), text=True, cwd=work, check=True,
        )
        os.replace(work / "combined.a", output)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit("usage: combine_archives.py ZIG OUTPUT INPUT...")
    combine(Path(sys.argv[1]), Path(sys.argv[2]), [Path(p) for p in sys.argv[3:]])
