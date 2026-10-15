"""Build-support regressions; run with python3 -m unittest discover -s tests -p test_core_build.py."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fingerprint = load("core_fingerprint", ROOT / "scripts/core-fingerprint.py").fingerprint
combine = load("combine_archives", ROOT / "core/src/build/combine_archives.py").combine


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="boome fingerprint ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.core = self.root / "core"
        self.core.mkdir()
        self.source = self.core / "source.zig"
        self.source.write_bytes(b"original")

    def digest(self, metadata=None, extra=None):
        return fingerprint(self.core, metadata or [], extra or [])

    def test_stable_for_unchanged_sources(self):
        self.assertEqual(self.digest(), self.digest())

    def test_content_changes_even_when_size_and_mtime_match(self):
        before = self.digest()
        stat = self.source.stat()
        self.source.write_bytes(b"modified")
        os.utime(self.source, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.assertNotEqual(before, self.digest())

    def test_new_and_deleted_sources_invalidate_the_build(self):
        before = self.digest()
        added = self.core / "new.zig"
        added.write_bytes(b"new")
        self.assertNotEqual(before, self.digest())
        added.unlink()
        self.assertEqual(before, self.digest())
        self.source.unlink()
        self.assertNotEqual(before, self.digest())

    def test_executable_mode_changes_invalidate_resources(self):
        before = self.digest()
        self.source.chmod(self.source.stat().st_mode ^ 0o100)
        self.assertNotEqual(before, self.digest())

    def test_renaming_a_source_changes_the_fingerprint(self):
        before = self.digest()
        self.source.rename(self.core / "renamed.zig")
        self.assertNotEqual(before, self.digest())

    def test_default_build_outputs_are_not_source_inputs(self):
        before = self.digest()
        for name in (".zig-cache", "zig-out", "__pycache__"):
            directory = self.core / name
            directory.mkdir()
            (directory / "generated").write_bytes(b"output")
        (self.core / ".DS_Store").write_bytes(b"metadata")
        self.assertEqual(before, self.digest())

    def test_toolchain_metadata_invalidates_the_build(self):
        self.assertNotEqual(self.digest(["sdk-a"]), self.digest(["sdk-b"]))

    def test_build_helper_changes_invalidate_the_build(self):
        helper = self.root / "helper.py"
        helper.write_bytes(b"old")
        before = self.digest(extra=[helper])
        helper.write_bytes(b"new")
        self.assertNotEqual(before, self.digest(extra=[helper]))

    def test_source_symlink_is_rejected(self):
        (self.core / "alias").symlink_to(self.source)
        with self.assertRaises(ValueError):
            self.digest()

    def test_external_source_directory_symlink_is_rejected(self):
        (self.core / "external").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.digest()

    def test_a_symlink_cannot_replace_the_core_directory(self):
        alias = self.root / "alias"
        alias.symlink_to(self.core, target_is_directory=True)
        with self.assertRaises(ValueError):
            fingerprint(alias, [], [])

    def test_missing_core_is_rejected(self):
        with self.assertRaises(ValueError):
            fingerprint(self.root / "missing", [], [])

    def test_missing_build_helper_is_rejected(self):
        with self.assertRaises(FileNotFoundError):
            self.digest(extra=[self.root / "missing.py"])


class RepositoryLayoutTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which("git"):
            self.skipTest("Git is required to verify source tracking rules")
        self.directory = tempfile.TemporaryDirectory(prefix="boome tracking rules ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        shutil.copy2(ROOT / ".gitignore", self.root / ".gitignore")
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)

    def ignored(self, paths):
        for name in paths:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        result = subprocess.run(
            ["git", "-C", str(self.root), "check-ignore", "--no-index", "--stdin"],
            input="\n".join(paths) + "\n", text=True, capture_output=True,
        )
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return set(result.stdout.splitlines())

    def test_nested_core_build_sources_are_not_ignored(self):
        sources = ["core/build.zig", "core/src/build/Config.zig",
                   "core/src/build/framegen/main.c",
                   "core/src/build/framegen/frames/frame_001.txt"]
        self.assertEqual(self.ignored(sources), set())

    def test_generated_outputs_and_python_caches_are_ignored(self):
        outputs = ["build/core/lib/libghostty.a", "core/.zig-cache/object.o",
                   "core/zig-out/lib/libghostty.a",
                   "core/src/build/__pycache__/combine_archives.pyc"]
        self.assertEqual(self.ignored(outputs), set(outputs))


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.zig = Path(os.environ.get("ZIG", str(Path.home() / ".local/zig/zig-aarch64-macos-0.15.2/zig")))
        if not self.zig.is_file() or not shutil.which("cc"):
            self.skipTest("Zig and the macOS C toolchain are required")
        self.directory = tempfile.TemporaryDirectory(prefix="boome archive merge ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def archive(self, index, function):
        directory = self.root / str(index)
        directory.mkdir()
        source = directory / "same.c"
        source.write_text(f"int {function}(void) {{ return {index}; }}\n")
        obj = directory / "same.o"
        subprocess.run(["cc", "-c", str(source), "-o", str(obj)], check=True)
        archive = directory / "input archive.a"
        subprocess.run([str(self.zig), "ar", "qc", str(archive), str(obj)], check=True)
        return archive

    def test_merges_duplicate_member_names_and_links_from_spaced_paths(self):
        archives = [self.archive(0, "boome_a"), self.archive(1, "boome_b")]
        output = self.root / "output directory/combined archive.a"
        combine(self.zig, output, archives)
        source = self.root / "main.c"
        source.write_text("int boome_a(void); int boome_b(void); int main(void) { return boome_a() + boome_b() - 1; }\n")
        executable = self.root / "linked program"
        subprocess.run(["cc", str(source), str(output), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
        self.assertFalse(any(output.parent.glob(".combine-*")))

    def test_missing_input_preserves_an_existing_output(self):
        output = self.root / "combined.a"
        output.write_bytes(b"existing output")
        with self.assertRaises(FileNotFoundError):
            combine(self.zig, output, [self.root / "missing.a"])
        self.assertEqual(output.read_bytes(), b"existing output")

    def test_invalid_archive_preserves_output_and_cleans_temporary_files(self):
        broken = self.root / "invalid.a"
        broken.write_bytes(b"not an archive")
        output = self.root / "combined.a"
        output.write_bytes(b"existing output")
        with self.assertRaises(subprocess.CalledProcessError):
            combine(self.zig, output, [broken])
        self.assertEqual(output.read_bytes(), b"existing output")
        self.assertFalse(any(output.parent.glob(".combine-*")))

    def test_an_empty_input_list_is_rejected(self):
        with self.assertRaises(ValueError):
            combine(self.zig, self.root / "combined.a", [])

    def test_an_input_cannot_be_its_own_output(self):
        archive = self.archive(0, "boome_only")
        before = archive.read_bytes()
        with self.assertRaises(ValueError):
            combine(self.zig, archive, [archive])
        self.assertEqual(archive.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
