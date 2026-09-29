import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
import ffkit_update as up

HOUR = 3600
NOW = 1_000_000.0
FILES = ("ffmpeg.exe", "ffprobe.exe", "ffplay.exe")


class Fake:
    """Injectable network/process boundary. Records every call, never touches the network."""

    def __init__(self, latest="9.0.2", installed="8.1.1", download_error=None, extract_error=None,
                 smoke=(True, "9.0.2"), replace_errors=()):
        self.latest = latest
        self.installed = installed
        self.download_error = download_error
        self.extract_error = extract_error
        self.smoke_result = smoke
        self.replace_errors = list(replace_errors)
        self.calls = []
        self.spawned = []
        self.clock = NOW

    def deps(self):
        return up.Deps(
            latest_version=self._latest,
            download=self._download,
            extract=self._extract,
            smoke=self._smoke,
            installed_version=self._installed,
            replace=self._replace,
            now=lambda: self.clock,
            spawn=self.spawned.append,
        )

    def _latest(self):
        self.calls.append("latest")
        return self.latest

    def _download(self, url, dest):
        self.calls.append("download")
        Path(dest).write_bytes(b"partial-zip")
        if self.download_error:
            raise self.download_error

    def _extract(self, zip_path, dest_dir):
        self.calls.append("extract")
        Path(dest_dir).mkdir(parents=True, exist_ok=True)
        (Path(dest_dir) / "ffmpeg.exe").write_bytes(b"NEW-ffmpeg")
        if self.extract_error:
            raise self.extract_error
        for name in FILES[1:]:
            (Path(dest_dir) / name).write_bytes(b"NEW-" + name.encode())

    def _smoke(self, path):
        self.calls.append("smoke")
        return self.smoke_result

    def _installed(self, exe):
        self.calls.append("installed")
        return self.installed

    def _replace(self, src, dst):
        self.calls.append("replace")
        if self.replace_errors:
            raise self.replace_errors.pop(0)
        os.replace(src, dst)


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.live_dir = root / "dependencies" / "ffmpeg"
        self.live_dir.mkdir(parents=True)
        for name in FILES:
            (self.live_dir / name).write_bytes(b"OLD-" + name.encode())
        self.paths = up.Paths.for_dir(self.live_dir, state_dir=root / "data" / "state", log_dir=root / "data" / "logs")
        self.fake = Fake()

    def write_state(self, **kw):
        self.paths.state.parent.mkdir(parents=True, exist_ok=True)
        self.paths.state.write_text(json.dumps(kw))

    def read_state(self):
        return json.loads(self.paths.state.read_text())

    def assert_live_is_old(self):
        for name in FILES:
            self.assertEqual((self.live_dir / name).read_bytes(), b"OLD-" + name.encode())


class TestResolve(Base):
    def test_fresh_check_spawns_nothing(self):
        self.write_state(last_check=NOW - HOUR)
        result = up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(result, self.live_dir / "ffmpeg.exe")
        self.assertEqual(self.fake.spawned, [])

    def test_stale_check_spawns_background_updater(self):
        self.write_state(last_check=NOW - 25 * HOUR)
        result = up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(result, self.live_dir / "ffmpeg.exe")
        self.assertEqual(len(self.fake.spawned), 1)
        argv = self.fake.spawned[0]
        self.assertIn("--run", argv)
        self.assertIn(str(self.live_dir), argv)

    def test_no_state_file_counts_as_stale(self):
        up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(len(self.fake.spawned), 1)

    def test_corrupt_state_counts_as_stale(self):
        self.paths.state.parent.mkdir(parents=True, exist_ok=True)
        self.paths.state.write_text("{not json")
        up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(len(self.fake.spawned), 1)

    def test_resolve_never_touches_network_or_binary(self):
        self.write_state(last_check=NOW - 100 * HOUR)
        up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(self.fake.calls, [])

    def test_resolve_never_blocks_on_a_hung_network(self):
        hang = threading.Event()
        deps = self.fake.deps()
        deps.latest_version = lambda: hang.wait()
        deps.download = lambda url, dest: hang.wait()
        out = []
        t = threading.Thread(target=lambda: out.append(up.resolve(self.live_dir, paths=self.paths, deps=deps)),
                             daemon=True)
        t.start()
        t.join(timeout=3)
        hang.set()
        self.assertFalse(t.is_alive(), "resolve blocked")
        self.assertEqual(out, [self.live_dir / "ffmpeg.exe"])

    def test_resolve_swallows_spawn_failure(self):
        deps = self.fake.deps()

        def boom(argv):
            raise OSError("no process for you")

        deps.spawn = boom
        self.assertEqual(up.resolve(self.live_dir, paths=self.paths, deps=deps), self.live_dir / "ffmpeg.exe")

    def test_resolve_skips_spawn_while_updater_holds_lock(self):
        with up.UpdateLock(self.paths.lock, now=lambda: NOW) as lock:
            self.assertTrue(lock.acquired)
            up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(self.fake.spawned, [])

    def test_pending_swap_retries_after_short_interval_only(self):
        self.write_state(last_check=NOW - 60, pending_swap=True)
        up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(self.fake.spawned, [])
        self.fake.clock = NOW + up.RETRY_INTERVAL_SECONDS + 1
        up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps())
        self.assertEqual(len(self.fake.spawned), 1)

    def test_defer_to_exit_registers_atexit_instead_of_spawning(self):
        with patch("ffkit_update.atexit.register") as reg:
            up.resolve(self.live_dir, paths=self.paths, deps=self.fake.deps(), defer_to_exit=True)
        reg.assert_called_once()
        self.assertEqual(self.fake.spawned, [])


class TestRunUpdate(Base):
    def test_up_to_date_stamps_and_stops(self):
        self.fake.installed = "9.0.2"
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "up_to_date")
        self.assert_live_is_old()
        self.assertNotIn("download", self.fake.calls)
        self.assertEqual(self.read_state()["last_check"], NOW)

    def test_successful_update_swaps_and_keeps_previous(self):
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "updated")
        for name in FILES:
            self.assertEqual((self.live_dir / name).read_bytes(), b"NEW-" + name.encode().replace(b"ffmpeg.exe", b"ffmpeg"))
            self.assertEqual((self.paths.previous / name).read_bytes(), b"OLD-" + name.encode())
        self.assertFalse(self.paths.new.exists())
        self.assertFalse(self.paths.zip.exists())
        self.assertFalse(self.read_state().get("pending_swap"))

    def test_older_previous_is_replaced_by_the_latest_old_version(self):
        self.paths.previous.mkdir()
        (self.paths.previous / "ffmpeg.exe").write_bytes(b"ANCIENT")
        (self.paths.previous / "stale-extra.txt").write_bytes(b"x")
        up.run_update(self.paths, self.fake.deps())
        self.assertEqual((self.paths.previous / "ffmpeg.exe").read_bytes(), b"OLD-ffmpeg.exe")
        self.assertFalse((self.paths.previous / "stale-extra.txt").exists())

    def test_stamp_is_written_before_the_network_call(self):
        seen = {}
        deps = self.fake.deps()
        real_latest = deps.latest_version

        def spy():
            seen["state"] = self.read_state()
            return real_latest()

        deps.latest_version = spy
        up.run_update(self.paths, deps)
        self.assertEqual(seen["state"]["last_check"], NOW)

    def test_crash_mid_update_does_not_cause_retry_storm(self):
        deps = self.fake.deps()

        def crash():
            raise RuntimeError("boom")

        deps.latest_version = crash
        up.run_update(self.paths, deps)
        self.assertFalse(up.is_stale(up.read_state(self.paths), NOW + HOUR))

    def test_version_check_failure_leaves_binary_alone(self):
        self.fake.latest = None
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "check_failed")
        self.assert_live_is_old()
        self.assertNotIn("download", self.fake.calls)

    def test_download_failure_leaves_live_binary_untouched(self):
        self.fake.download_error = OSError("connection reset")
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "download_failed")
        self.assert_live_is_old()
        self.assertFalse(self.paths.zip.exists(), "half-written download must be removed")
        self.assertFalse(self.paths.new.exists())
        self.assertFalse(self.paths.previous.exists())
        self.assertNotIn("replace", self.fake.calls)

    def test_bad_archive_leaves_live_binary_untouched(self):
        self.fake.extract_error = ValueError("bad zip")
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "download_failed")
        self.assert_live_is_old()
        self.assertFalse(self.paths.new.exists())
        self.assertFalse(self.paths.zip.exists())

    def test_smoke_failure_leaves_live_binary_untouched(self):
        self.fake.smoke_result = (False, "exit 1")
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "smoke_failed")
        self.assert_live_is_old()
        self.assertFalse(self.paths.new.exists())
        self.assertNotIn("replace", self.fake.calls)

    def test_locked_exe_keeps_new_and_marks_pending(self):
        self.fake.replace_errors = [PermissionError("in use")]
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "swap_locked")
        self.assert_live_is_old()
        self.assertEqual((self.paths.new / "ffmpeg.exe").read_bytes(), b"NEW-ffmpeg")
        self.assertTrue(self.read_state()["pending_swap"])

    def test_locked_exe_retry_completes_without_redownloading(self):
        self.fake.replace_errors = [PermissionError("in use")]
        up.run_update(self.paths, self.fake.deps())
        self.fake.calls.clear()
        self.fake.clock = NOW + up.RETRY_INTERVAL_SECONDS + 1
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "updated")
        self.assertNotIn("download", self.fake.calls)
        self.assertEqual((self.live_dir / "ffmpeg.exe").read_bytes(), b"NEW-ffmpeg")
        self.assertEqual((self.paths.previous / "ffmpeg.exe").read_bytes(), b"OLD-ffmpeg.exe")
        self.assertFalse(self.read_state()["pending_swap"])

    def test_retry_with_bad_staged_files_discards_them(self):
        self.fake.replace_errors = [PermissionError("in use")]
        up.run_update(self.paths, self.fake.deps())
        self.fake.smoke_result = (False, "corrupt")
        self.fake.clock = NOW + up.RETRY_INTERVAL_SECONDS + 1
        up.run_update(self.paths, self.fake.deps())
        self.assert_live_is_old()
        self.assertFalse(self.paths.new.exists())

    @unittest.skipUnless(sys.platform == "win32", "real file lock semantics are Windows-specific")
    def test_really_locked_file_on_windows(self):
        deps = self.fake.deps()
        deps.replace = os.replace
        with open(self.live_dir / "ffmpeg.exe", "r+b"):
            status = up.run_update(self.paths, deps)
        self.assertEqual(status, "swap_locked")
        self.assert_live_is_old()

    def test_partial_swap_is_rolled_back(self):
        # ffmpeg.exe swaps, then the second file fails: live must be all-old again, never a version mix.
        deps = self.fake.deps()
        real = deps.replace
        state = {"n": 0}

        def flaky(src, dst):
            state["n"] += 1
            if state["n"] == 2:
                raise OSError("disk error")
            real(src, dst)

        deps.replace = flaky
        self.assertEqual(up.run_update(self.paths, deps), "swap_failed")
        self.assert_live_is_old()
        self.assertFalse(self.paths.new.exists())

    def test_first_file_failing_with_other_error_cleans_up(self):
        self.fake.replace_errors = [OSError("disk full")]
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "swap_failed")
        self.assert_live_is_old()
        self.assertFalse(self.paths.new.exists())

    def test_concurrent_lock_second_updater_backs_off(self):
        with up.UpdateLock(self.paths.lock, now=lambda: NOW) as held:
            self.assertTrue(held.acquired)
            self.assertEqual(up.run_update(self.paths, self.fake.deps()), "busy")
        self.assertEqual(self.fake.calls, [])
        self.assert_live_is_old()

    def test_lock_is_released_after_run(self):
        up.run_update(self.paths, self.fake.deps())
        self.assertFalse(self.paths.lock.exists())

    def test_lock_is_released_even_on_crash(self):
        deps = self.fake.deps()
        deps.latest_version = lambda: (_ for _ in ()).throw(RuntimeError("boom"))
        up.run_update(self.paths, deps)
        self.assertFalse(self.paths.lock.exists())

    def test_stale_lock_from_dead_updater_is_reclaimed(self):
        self.paths.lock.parent.mkdir(parents=True, exist_ok=True)
        self.paths.lock.write_text("123")
        os.utime(self.paths.lock, (NOW - 3 * HOUR, NOW - 3 * HOUR))
        with up.UpdateLock(self.paths.lock, now=lambda: NOW) as lock:
            self.assertTrue(lock.acquired)

    def test_two_threads_only_one_gets_the_lock(self):
        results = []
        barrier = threading.Barrier(2)

        def worker():
            barrier.wait()
            with up.UpdateLock(self.paths.lock, now=lambda: NOW) as lock:
                results.append(lock.acquired)
                threading.Event().wait(0.2)

        ts = [threading.Thread(target=worker) for _ in range(2)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(sorted(results), [False, True])


class TestDetachedSpawn(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32", "Windows creation flags")
    def test_windows_uses_detached_flags_and_no_console(self):
        with patch("ffkit_update.subprocess.Popen") as popen:
            up.spawn_detached(["python", "x.py", "--run"])
        kwargs = popen.call_args.kwargs
        flags = kwargs["creationflags"]
        self.assertTrue(flags & subprocess.DETACHED_PROCESS)
        self.assertTrue(flags & subprocess.CREATE_NEW_PROCESS_GROUP)
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    def test_spawn_does_not_wait_on_the_child(self):
        with patch("ffkit_update.subprocess.Popen") as popen:
            up.spawn_detached(["python", "x.py", "--run"])
        popen.return_value.wait.assert_not_called()
        popen.return_value.communicate.assert_not_called()


class TestCli(Base):
    def test_status_reports_without_side_effects(self):
        self.write_state(last_check=NOW - 30 * HOUR, last_result="up_to_date")
        text = up.format_status(self.paths, self.fake.deps())
        self.assertIn("stale", text)
        self.assertIn("up_to_date", text)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.fake.spawned, [])

    def test_status_fresh(self):
        self.write_state(last_check=NOW - HOUR)
        self.assertIn("fresh", up.format_status(self.paths, self.fake.deps()))

    def test_check_starts_updater_only_when_stale(self):
        self.write_state(last_check=NOW - HOUR)
        self.assertEqual(up.check(self.paths, self.fake.deps()), "fresh")
        self.assertEqual(self.fake.spawned, [])
        self.write_state(last_check=NOW - 30 * HOUR)
        self.assertEqual(up.check(self.paths, self.fake.deps()), "started")
        self.assertEqual(len(self.fake.spawned), 1)

    def test_run_force_ignores_freshness(self):
        self.write_state(last_check=NOW - 60)
        self.assertEqual(up.run_update(self.paths, self.fake.deps(), force=True), "updated")

    def test_run_without_force_skips_when_fresh(self):
        self.write_state(last_check=NOW - 60)
        self.assertEqual(up.run_update(self.paths, self.fake.deps()), "fresh")
        self.assertEqual(self.fake.calls, [])


class TestVersionHelpers(unittest.TestCase):
    def test_parse_ffmpeg_banner(self):
        banner = "ffmpeg version 9.0.2-essentials_build-www.gyan.dev Copyright (c) 2000-2026 the FFmpeg developers"
        self.assertEqual(up.parse_version(banner), "9.0.2")

    def test_parse_plain_release_version(self):
        self.assertEqual(up.parse_version("9.0.2\n"), "9.0.2")

    def test_parse_git_build_banner_is_kept_whole(self):
        self.assertEqual(up.parse_version("ffmpeg version N-118000-gabcdef"), "N-118000-gabcdef")

    def test_parse_garbage_is_none(self):
        self.assertIsNone(up.parse_version(""))
        self.assertIsNone(up.parse_version(None))


class TestExtract(unittest.TestCase):
    def test_extract_flattens_bin_executables_and_ignores_path_tricks(self):
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            zpath = Path(tmp) / "f.zip"
            with zipfile.ZipFile(zpath, "w") as z:
                z.writestr("ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe", b"A")
                z.writestr("ffmpeg-9.0.2-essentials_build/bin/ffprobe.exe", b"B")
                z.writestr("ffmpeg-9.0.2-essentials_build/doc/readme.txt", b"C")
                z.writestr("../evil/bin/evil.exe", b"D")
            dest = Path(tmp) / "out"
            up.extract_bin(zpath, dest)
            self.assertEqual(sorted(p.name for p in dest.iterdir()), ["evil.exe", "ffmpeg.exe", "ffprobe.exe"])
            self.assertFalse((Path(tmp) / "evil").exists())

    def test_extract_without_ffmpeg_exe_raises(self):
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            zpath = Path(tmp) / "f.zip"
            with zipfile.ZipFile(zpath, "w") as z:
                z.writestr("x/bin/other.exe", b"A")
            with self.assertRaises(ValueError):
                up.extract_bin(zpath, Path(tmp) / "out")


if __name__ == "__main__":
    unittest.main()
