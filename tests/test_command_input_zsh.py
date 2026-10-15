"""Real ZLE/PTY protocol checks; no GUI, user profiles, or shell code evaluation."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import termios
import time
import unittest
import uuid

SCRIPT = Path(__file__).resolve().parents[1] / "core/src/shell-integration/zsh/boome-input"


class Shell:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="boome zle ")
        self.root = Path(self.temp.name)
        os.chmod(self.root, 0o700)
        self.token = str(uuid.uuid4())
        (self.root / "token").write_text(self.token)
        os.mkfifo(self.root / "notify", 0o600)
        self.master, slave = pty.openpty()
        env = dict(os.environ, HOME=str(self.root), ZDOTDIR=str(self.root),
                   BOOME_INPUT_DIR=str(self.root), TERM="xterm-256color", LANG="en_US.UTF-8")
        self.process = subprocess.Popen(
            ["/bin/zsh", "-d", "-f", "-i"], stdin=slave, stdout=slave, stderr=slave,
            env=env, cwd=self.root, start_new_session=True,
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        os.set_blocking(self.master, False)
        self.output = bytearray()
        self.commit_keys = {}
        self.send("source " + shlex.quote(str(SCRIPT)) + "\n")
        self.wait(lambda s: s and s[6] == "ready")

    def send(self, text):
        os.write(self.master, text.encode())

    def state(self):
        try:
            fields = (self.root / "state").read_bytes().split(b"\0")
            return [v.decode() for v in fields[:-1]] if len(fields) == 14 else None
        except (FileNotFoundError, UnicodeError):
            return None

    def wait(self, predicate, timeout=4):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if select.select([self.master], [], [], 0.02)[0]:
                try:
                    self.output.extend(os.read(self.master, 65536))
                except BlockingIOError:
                    pass
            state = self.state()
            if state and state[6] == "armed" and state[11] in self.commit_keys:
                self.send(self.commit_keys.pop(state[11]))
                continue
            if predicate(state):
                return state
        raise AssertionError("ZLE timeout: " + repr(self.state()) + " output=" + repr(bytes(self.output[-2500:])))

    def request(self, action, text="", cursor=None, snapshot=None, expires=None, token=None, identity=None, auto_commit=True):
        state = snapshot or self.state()
        identity = identity or str(uuid.uuid4())
        fields = ["BOOME1", token or self.token, state[3], state[4], state[5], identity,
                  action, str(expires if expires is not None else int(time.time()) + 4),
                  text, str(len(text) if cursor is None else cursor)]
        temporary = self.root / ".request"
        temporary.write_bytes(b"\0".join(v.encode() for v in fields) + b"\0")
        temporary.replace(self.root / "request")
        if action in ("submit", "complete", "search") and auto_commit:
            self.commit_keys[identity] = "\x1b[99;" + identity + "~"
        fd = os.open(self.root / "notify", os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, b".")
        os.close(fd)
        return identity

    def close(self):
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait()
        os.close(self.master)
        self.temp.cleanup()


@unittest.skipUnless(Path("/bin/zsh").exists(), "zsh required")
class ZLETests(unittest.TestCase):
    def setUp(self):
        self.shell = Shell()
        self.addCleanup(self.shell.close)

    def test_literal_unicode_multiline_handoff(self):
        text = "echo '中文👩‍💻'\n# $(touch NEVER)\n"
        identity = self.shell.request("terminal", text, 8)
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[12], "accepted")
        self.assertEqual(state[7], text)
        self.assertEqual(state[8], "8")
        self.assertFalse((self.shell.root / "NEVER").exists())

    def test_submission_uses_original_shell_and_accept_line(self):
        path = self.shell.root / "result"
        command = "LOCAL_VALUE=kept; printf '%s:%s' \"$LOCAL_VALUE\" $$ > " + shlex.quote(str(path))
        identity = self.shell.request("submit", command)
        state = self.shell.wait(lambda s: s and s[11] == identity and s[6] == "ready" and path.exists())
        self.assertEqual(state[12], "accepted")
        self.assertEqual(path.read_text(), "kept:" + str(self.shell.process.pid))
        self.assertEqual(state[7], "")

    def test_stale_revision_is_rejected_without_replacing_shell_text(self):
        old = self.shell.state()
        self.shell.send("existing")
        self.shell.wait(lambda s: s and s[7] == "existing")
        identity = self.shell.request("submit", "touch NEVER", snapshot=old)
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[12], "rejected")
        self.assertEqual(state[7], "existing")

    def test_request_during_program_does_not_enter_pty_or_execute_later(self):
        old = self.shell.state()
        self.shell.send("sleep 0.3\n")
        self.shell.wait(lambda s: s and s[6] == "busy")
        identity = self.shell.request("submit", "touch NEVER", snapshot=old)
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[12], "rejected")
        self.assertEqual(state[7], "")
        self.assertFalse((self.shell.root / "NEVER").exists())

    def test_expired_request_is_rejected(self):
        identity = self.shell.request("submit", "touch NEVER", expires=int(time.time()) - 1)
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[12], "rejected")

    def test_history_can_be_used_after_native_submission(self):
        for text in ["echo first", "echo second"]:
            old = self.shell.state()
            identity = self.shell.request("submit", text)
            self.shell.wait(lambda s: s and s[11] == identity and s[6] == "ready" and s[4] != old[4])
        identity = self.shell.request("previous")
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[7], "echo second")

    def test_armed_submission_can_be_cancelled_without_execution(self):
        identity = self.shell.request("submit", "touch NEVER", auto_commit=False)
        armed = self.shell.wait(lambda s: s and s[6] == "armed")
        self.shell.request("abort", snapshot=armed, identity=identity)
        state = self.shell.wait(lambda s: s and s[11] == identity and s[12] == "rejected")
        self.assertEqual(state[9], "main")
        self.assertEqual(state[7], "")
        self.assertFalse((self.shell.root / "NEVER").exists())
        self.shell.send("echo restored > '" + str(self.shell.root / "restored") + "'\n")
        self.shell.wait(lambda s: (self.shell.root / "restored").exists())

    def test_wrong_token_never_changes_shell_buffer(self):
        self.shell.request("terminal", "touch NEVER", token="wrong")
        time.sleep(0.05)
        self.assertEqual(self.shell.state()[7], "")
        self.assertFalse((self.shell.root / "NEVER").exists())

    def test_repeated_history_keeps_original_zsh_history_position(self):
        for text in ["echo alpha", "echo beta"]:
            old = self.shell.state()
            identity = self.shell.request("submit", text)
            self.shell.wait(lambda s: s and s[11] == identity and s[6] == "ready" and s[4] != old[4])
        identity = self.shell.request("previous")
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[7], "echo beta")
        identity = self.shell.request("previous", state[7], int(state[8]))
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[7], "echo alpha")

    def test_shell_completion_keeps_the_original_shell_completer(self):
        (self.shell.root / "alpha_file").write_text("")
        identity = self.shell.request("complete", "cat alph")
        state = self.shell.wait(lambda s: s and s[11] == identity and s[7].startswith("cat alpha_file"))
        self.assertEqual(state[12], "accepted")

    def test_search_handoff_suspends_native_editor_until_exit(self):
        old = self.shell.state()
        identity = self.shell.request("submit", "echo searchable")
        self.shell.wait(lambda s: s and s[11] == identity and s[6] == "ready" and s[4] != old[4])
        identity = self.shell.request("search")
        self.shell.wait(lambda s: s and s[11] == identity and s[6] == "unsupported")
        self.shell.send("\x07")
        self.shell.wait(lambda s: s and s[6] == "ready")

    def test_search_enter_executes_without_an_extra_keypress(self):
        output = self.shell.root / "search-result"
        command = "printf BOOME_SEARCH > " + shlex.quote(str(output))
        old = self.shell.state()
        identity = self.shell.request("submit", command)
        self.shell.wait(lambda s: s and s[11] == identity and s[6] == "ready" and s[4] != old[4])
        output.unlink()
        identity = self.shell.request("search")
        self.shell.wait(lambda s: s and s[11] == identity and s[6] == "unsupported")
        self.shell.send("BOOME_SEARCH\r")
        self.shell.wait(lambda s: output.exists())
        self.assertEqual(output.read_text(), "BOOME_SEARCH")

    def test_terminal_initiated_search_is_not_a_native_editable_prompt(self):
        self.shell.send("\x12")
        self.shell.wait(lambda s: s and s[6] == "unsupported")
        self.shell.send("\x07")
        self.shell.wait(lambda s: s and s[6] == "ready")

    def test_shell_nonempty_cancel_is_local_edit(self):
        identity = self.shell.request("cancel", "do not execute")
        state = self.shell.wait(lambda s: s and s[11] == identity)
        self.assertEqual(state[7], "")
        self.assertEqual(state[12], "accepted")


if __name__ == "__main__":
    unittest.main()
