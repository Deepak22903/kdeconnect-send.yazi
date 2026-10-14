"""Smoke-test the plugin in a real, isolated Yazi; never contact KDE Connect."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import zipfile

scratch = os.environ.get("TMPDIR")
with tempfile.TemporaryDirectory(prefix="yazi-kdeconnect-test-", dir=scratch) as temp:
    root = Path(temp)
    config = root / "config"
    plugin = config / "plugins/kdeconnect-send.yazi"
    plugin.mkdir(parents=True)
    source = Path(os.environ.get("PLUGIN_PATH", "main.lua"))
    shutil.copyfile(source, plugin / "main.lua")
    (config / "keymap.toml").write_text('[[mgr.prepend_keymap]]\non = "s"\nrun = "plugin kdeconnect-send"\n')
    folder = root / "input/Test folder"
    (folder / "nested").mkdir(parents=True)
    (folder / "nested/data.txt").write_text("real Yazi test\n")
    bindir = root / "bin"
    bindir.mkdir()
    cli = bindir / "kdeconnect-cli"
    cli.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args == ["-a"]:
    print("- Mock Phone: mock-id (paired and reachable)\\n1 device found")
elif args[0] == "--share":
    Path(os.environ["MOCK_SHARE_LOG"]).write_text(json.dumps(args))
else:
    raise SystemExit("unexpected CLI call")
''')
    cli.chmod(0o700)
    log = root / "share.json"
    attempt = root / "zip-attempt.txt"
    failing_zip = bool(os.getenv("TEST_ZIP_FAILURE"))
    if failing_zip:
        zip_command = bindir / "zip"
        zip_command.write_text(f"#!{sys.executable}\n" + '''import os, sys
from pathlib import Path
archive = Path(sys.argv[5])
archive.write_bytes(b"partial archive")
Path(os.environ["MOCK_ZIP_ATTEMPT"]).write_text(str(archive))
raise SystemExit(1)
''')
        zip_command.chmod(0o700)
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
               YAZI_CONFIG_HOME=str(config), XDG_STATE_HOME=str(root / "state"),
               XDG_CACHE_HOME=str(root / "cache"), TMPDIR=str(root),
               MOCK_SHARE_LOG=str(log), MOCK_ZIP_ATTEMPT=str(attempt), TERM="xterm-256color")
    # Do not join an existing user's Yazi session.
    for key in list(env):
        if key.startswith("YAZI_") and key != "YAZI_CONFIG_HOME":
            env.pop(key)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 140, 0, 0))
    process = subprocess.Popen(["yazi", str(folder.parent)], stdin=slave, stdout=slave,
                               stderr=slave, env=env, start_new_session=True)
    os.close(slave)
    output = bytearray()
    def drain(duration):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            ready, _, _ = select.select([master], [], [], min(0.1, max(0, end - time.monotonic())))
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
    try:
        drain(1.5)
        os.write(master, b"s")
        deadline = time.monotonic() + 12
        marker = attempt if failing_zip else log
        while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
            drain(0.1)
        assert marker.exists(), "Yazi did not invoke the plugin: " + output.decode(errors="replace")[-6000:]
        if failing_zip:
            archive = Path(attempt.read_text())
            while archive.parent.exists() and time.monotonic() < deadline:
                drain(0.1)
            assert not archive.parent.exists(), "failed archive's private directory was not cleaned"
            assert not log.exists(), "failed ZIP must never be queued"
            print("PASS: real Yazi removes a partial ZIP and private directory after packing failure")
        else:
            args = json.loads(log.read_text())
            assert args[2:] == ["--device", "mock-id"], args
            archive = Path(args[1])
            assert archive.name == "Test folder.zip"
            with zipfile.ZipFile(archive) as zipped:
                assert zipped.read("Test folder/nested/data.txt") == b"real Yazi test\n"
                assert all(i.compress_type == zipfile.ZIP_STORED for i in zipped.infolist())
            assert archive.exists(), "archive must remain after CLI return"
            print("PASS: real Yazi loaded plugin, archived folder with real zip, and invoked mock CLI")
        assert (folder / "nested/data.txt").read_text() == "real Yazi test\n", "source files must survive"
        print("No real KDE Connect device was contacted.")
    finally:
        os.write(master, b"q")
        drain(0.3)
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        os.close(master)
