"""
Non-blocking background updater for the shared FFmpeg binaries (stale-while-revalidate).

resolve() returns the current ffmpeg.exe at once and never touches the network. When the last check is more than 24
hours old it starts a detached updater process. The updater downloads the release zip, extracts it to
dependencies/ffmpeg.new/, runs a -version smoke test on the new ffmpeg.exe, keeps the old files in
dependencies/ffmpeg.previous/, then swaps each file with os.replace. A failed download or smoke test never touches
the live binaries. If ffmpeg.exe is locked (Windows, in use) the staged files are kept and the swap is retried later.

Usage:
  python scripts/ffkit_update.py --resolve   print the ffmpeg.exe path and trigger a background update if stale
  python scripts/ffkit_update.py --status    show last check, staleness and pending state (no side effects)
  python scripts/ffkit_update.py --check     start the background updater if stale (does not wait)
  python scripts/ffkit_update.py --run       run the updater in the foreground (add --force to skip the 24h rule)
"""

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

REPO_ROOT = Path(__file__).parent.parent
DEFAULT_DIR = REPO_ROOT / "dependencies" / "ffmpeg"
STATE_DIR = REPO_ROOT / "data" / "state"
LOG_DIR = REPO_ROOT / "data" / "logs"

CHECK_INTERVAL_SECONDS = 24 * 3600
RETRY_INTERVAL_SECONDS = 15 * 60
LOCK_STALE_SECONDS = 3600

EXE_NAME = "ffmpeg.exe"
RELEASE_VERSION_URL = "https://www.gyan.dev/ffmpeg/builds/release-version"
DOWNLOAD_URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
USER_AGENT = "ffkit-updater"


@dataclass
class Paths:
    live: Path
    new: Path
    previous: Path
    zip: Path
    state: Path
    lock: Path
    log: Path

    @property
    def exe(self):
        return self.live / EXE_NAME

    @classmethod
    def for_dir(cls, live, state_dir=STATE_DIR, log_dir=LOG_DIR):
        live = Path(live)
        return cls(
            live=live,
            new=live.with_name(f"{live.name}.new"),
            previous=live.with_name(f"{live.name}.previous"),
            zip=live.with_name(f"{live.name}.new.zip"),
            state=Path(state_dir) / "ffkit_update_check.json",
            lock=Path(state_dir) / "ffkit_update.lock",
            log=Path(log_dir) / "ffkit_update.log",
        )


@dataclass
class Deps:
    """Every network and process boundary. Tests inject fakes; nothing else touches the outside world."""
    latest_version: Callable[[], Optional[str]]
    download: Callable[[str, Path], None]
    extract: Callable[[Path, Path], None]
    smoke: Callable[[Path], tuple]
    installed_version: Callable[[Path], Optional[str]]
    replace: Callable[[Path, Path], None]
    now: Callable[[], float]
    spawn: Callable[[list], None]


# ---------------------------------------------------------------- real boundaries

def parse_version(text):
    """'ffmpeg version 9.0.2-essentials_build-...' or '9.0.2' -> '9.0.2'. Git builds keep their whole token."""
    if not text:
        return None
    m = re.search(r"(?:ffmpeg version\s+)?(\d+(?:\.\d+)+)", text.strip())
    if m:
        return m.group(1)
    m = re.search(r"ffmpeg version\s+(\S+)", text)
    return m.group(1) if m else None


def fetch_latest_version():
    """Latest release version from the release-version endpoint, or None on any failure."""
    try:
        req = urllib.request.Request(RELEASE_VERSION_URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return parse_version(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None


def download_file(url, dest):
    """Stream url to dest. Raises on network error or a size mismatch (truncated download)."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    Path(dest).parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(req, timeout=60) as resp:
        expected = int(resp.headers.get("Content-Length") or 0)
        written = 0
        with open(dest, "wb") as f:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                written += len(chunk)
    if expected and written != expected:
        raise IOError(f"truncated download: got {written} of {expected} bytes")


def extract_bin(zip_path, dest_dir):
    """Extract every .exe under a bin/ folder of the release zip into dest_dir, flattened (basename only, so an
    archive path can never write outside dest_dir). Raises ValueError if there is no ffmpeg.exe."""
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            name = info.filename.replace("\\", "/")
            if info.is_dir() or "/bin/" not in "/" + name or not name.lower().endswith(".exe"):
                continue
            with z.open(info) as src, open(dest_dir / Path(name).name, "wb") as out:
                shutil.copyfileobj(src, out)
    if not (dest_dir / EXE_NAME).exists():
        raise ValueError(f"{EXE_NAME} not found in archive")


def _quiet_flags():
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


def smoke_test(path):
    """(ok, detail): the file runs -version with exit 0 and prints an ffmpeg banner."""
    try:
        result = subprocess.run([str(path), "-version"], capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=30, creationflags=_quiet_flags())
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"
    out = (result.stdout or "").strip()
    first = out.splitlines()[0] if out else ""
    if result.returncode != 0 or "ffmpeg version" not in first:
        return False, f"exit {result.returncode}, output {first[:80]!r}"
    return True, parse_version(first) or first


def installed_version(exe):
    if not Path(exe).exists():
        return None
    ok, detail = smoke_test(exe)
    return detail if ok else None


def spawn_detached(argv):
    """Start argv as a fully detached process (no console window, not waited on)."""
    kwargs = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen(argv, **kwargs)


def real_deps():
    return Deps(latest_version=fetch_latest_version, download=download_file, extract=extract_bin, smoke=smoke_test,
                installed_version=installed_version, replace=os.replace, now=time.time, spawn=spawn_detached)


def _background_python():
    """pythonw.exe (no console) beside the running interpreter when present."""
    exe = Path(sys.executable)
    pythonw = exe.with_name("pythonw.exe")
    return str(pythonw) if sys.platform == "win32" and pythonw.exists() else str(exe)


def updater_argv(live):
    return [_background_python(), str(Path(__file__).resolve()), "--run", "--dir", str(live)]


# ---------------------------------------------------------------- state, lock, log

def read_state(paths):
    try:
        data = json.loads(paths.state.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(paths, state):
    """Atomic write: a crash never leaves a half-written state file."""
    paths.state.parent.mkdir(parents=True, exist_ok=True)
    tmp = paths.state.with_name(paths.state.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    os.replace(tmp, paths.state)


def log(paths, message, now=time.time):
    try:
        paths.log.parent.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now()))
        with open(paths.log, "a", encoding="utf-8") as f:
            f.write(f"{stamp} {message}\n")
    except Exception:
        pass


def is_stale(state, now):
    last = state.get("last_check")
    if not isinstance(last, (int, float)) or isinstance(last, bool):
        return True
    age = now - last
    if age < 0:
        return True
    if state.get("pending_swap"):
        return age >= RETRY_INTERVAL_SECONDS
    return age >= CHECK_INTERVAL_SECONDS


class UpdateLock:
    """Single-instance lock: exclusive create of a lock file. A lock older than an hour is from a dead updater."""

    def __init__(self, path, now=time.time):
        self.path = Path(path)
        self.now = now
        self.acquired = False

    def _try_create(self):
        fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        try:
            os.write(fd, str(os.getpid()).encode())
        finally:
            os.close(fd)

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._try_create()
            self.acquired = True
        except FileExistsError:
            try:
                age = self.now() - self.path.stat().st_mtime
            except OSError:
                age = 0
            if age > LOCK_STALE_SECONDS:
                try:
                    self.path.unlink()
                    self._try_create()
                    self.acquired = True
                except OSError:
                    self.acquired = False
        return self

    def __exit__(self, *exc):
        if self.acquired:
            try:
                self.path.unlink()
            except OSError:
                pass
        self.acquired = False
        return False


def lock_held(paths, now):
    try:
        return (now - paths.lock.stat().st_mtime) <= LOCK_STALE_SECONDS
    except OSError:
        return False


# ---------------------------------------------------------------- resolve (the fast path)

def _maybe_spawn(paths, deps):
    try:
        if is_stale(read_state(paths), deps.now()) and not lock_held(paths, deps.now()):
            deps.spawn(updater_argv(paths.live))
            return True
    except Exception as exc:
        log(paths, f"EVENT=spawn_failed error={exc!r}")
    return False


def resolve(live=None, paths=None, deps=None, defer_to_exit=False):
    """Return the current ffmpeg.exe path at once. Never checks the network, never blocks.
    If the last check is stale, a detached updater is started (or, with defer_to_exit, at interpreter exit so the
    running task is never slowed)."""
    live = Path(live) if live else DEFAULT_DIR
    paths = paths or Paths.for_dir(live)
    deps = deps or real_deps()
    if defer_to_exit:
        atexit.register(_maybe_spawn, paths, deps)
    else:
        _maybe_spawn(paths, deps)
    return live / EXE_NAME


# ---------------------------------------------------------------- the updater (runs detached)

def _remove_file(path):
    try:
        Path(path).unlink()
    except OSError:
        pass


def _remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)


def _staged_names(paths):
    """Staged files, ffmpeg.exe first: the binary most likely to be in use fails the swap before anything moves."""
    names = sorted(p.name for p in paths.new.iterdir() if p.is_file())
    return sorted(names, key=lambda n: (n != EXE_NAME, n))


def _rollback(paths, deps, swapped):
    for name in reversed(swapped):
        try:
            tmp = paths.live / (name + ".rollback")
            shutil.copy2(paths.previous / name, tmp)
            deps.replace(tmp, paths.live / name)
        except Exception as exc:
            log(paths, f"EVENT=rollback_failed file={name} error={exc!r}", deps.now)


def _swap_in(paths, deps):
    """Copy the old files to .previous, then swap each staged file in with os.replace.
    Returns 'updated', 'swap_locked' (nothing moved, staged files kept for a retry) or 'swap_failed'."""
    swapped = []
    try:
        names = _staged_names(paths)
        _remove_tree(paths.previous)
        paths.previous.mkdir(parents=True, exist_ok=True)
        for name in names:
            if (paths.live / name).exists():
                shutil.copy2(paths.live / name, paths.previous / name)
        for name in names:
            deps.replace(paths.new / name, paths.live / name)
            swapped.append(name)
        _remove_tree(paths.new)
        return "updated"
    except PermissionError as exc:
        if not swapped:
            log(paths, f"EVENT=swap_locked error={exc!r} kept={EXE_NAME}", deps.now)
            return "swap_locked"
        error = exc
    except Exception as exc:
        error = exc
    log(paths, f"EVENT=swap_failed error={error!r} rolled_back={swapped}", deps.now)
    _rollback(paths, deps, swapped)
    _remove_tree(paths.new)
    return "swap_failed"


def run_update(paths, deps, force=False):
    """One update attempt. Returns a status string; never raises."""
    with UpdateLock(paths.lock, now=deps.now) as lock:
        if not lock.acquired:
            return "busy"
        try:
            state = read_state(paths)
            now = deps.now()
            if not force and not is_stale(state, now):
                return "fresh"
            pending = bool(state.get("pending_swap")) and (paths.new / EXE_NAME).exists()
            # Stamp BEFORE any network call so a crash cannot cause a retry storm.
            state.update(last_check=now, pending_swap=pending)
            write_state(paths, state)

            status = _finish_staged(paths, deps) if pending else _fetch_and_stage(paths, deps, state)
            state["last_result"] = status
            state["pending_swap"] = status == "swap_locked"
            write_state(paths, state)
            log(paths, f"EVENT=update_result status={status}", deps.now)
            return status
        except Exception as exc:
            log(paths, f"EVENT=update_error error={exc!r}", deps.now)
            return "error"


def _finish_staged(paths, deps):
    ok, detail = deps.smoke(paths.new / EXE_NAME)
    if not ok:
        log(paths, f"EVENT=update_rejected reason={'staged smoke test failed ' + detail!r}", deps.now)
        _remove_tree(paths.new)
        return "smoke_failed"
    return _swap_in(paths, deps)


def _fetch_and_stage(paths, deps, state):
    latest = deps.latest_version()
    if not latest:
        return "check_failed"
    current = deps.installed_version(paths.exe)
    state.update(latest=latest, current=current)
    if current == latest:
        return "up_to_date"
    _remove_tree(paths.new)
    try:
        deps.download(DOWNLOAD_URL, paths.zip)
        deps.extract(paths.zip, paths.new)
    except Exception as exc:
        log(paths, f"EVENT=update_rejected reason={'download failed ' + repr(exc)!r} kept={EXE_NAME}", deps.now)
        _remove_tree(paths.new)
        return "download_failed"
    finally:
        _remove_file(paths.zip)
    ok, detail = deps.smoke(paths.new / EXE_NAME)
    if not ok:
        log(paths, f"EVENT=update_rejected reason={'smoke test failed ' + detail!r} kept={EXE_NAME}", deps.now)
        _remove_tree(paths.new)
        return "smoke_failed"
    status = _swap_in(paths, deps)
    if status == "updated":
        state["current"] = latest
        log(paths, f"EVENT=updated from={current} to={latest} previous={paths.previous.name}", deps.now)
    return status


# ---------------------------------------------------------------- CLI

def check(paths, deps):
    """Start the background updater if stale. Returns 'started' or 'fresh'."""
    return "started" if _maybe_spawn(paths, deps) else "fresh"


def format_status(paths, deps):
    state = read_state(paths)
    now = deps.now()
    last = state.get("last_check")
    lines = [f"binary:       {paths.exe} ({'present' if paths.exe.exists() else 'missing'})"]
    if isinstance(last, (int, float)):
        lines.append(f"last check:   {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(last))} "
                     f"({(now - last) / 3600:.1f}h ago)")
    else:
        lines.append("last check:   never")
    lines.append(f"state:        {'stale (an update check is due)' if is_stale(state, now) else 'fresh'}")
    lines.append(f"last result:  {state.get('last_result', 'none')}")
    lines.append(f"pending swap: {'yes (staged files waiting for ffmpeg.exe to be free)' if state.get('pending_swap') else 'no'}")
    lines.append(f"previous:     {'kept' if paths.previous.exists() else 'none'}")
    lines.append(f"updater:      {'running' if lock_held(paths, now) else 'idle'}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="ffkit - background FFmpeg updater")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--resolve", action="store_true", help="print the ffmpeg.exe path, trigger update if stale")
    mode.add_argument("--status", action="store_true", help="show update state, no side effects")
    mode.add_argument("--check", action="store_true", help="start the background updater if stale")
    mode.add_argument("--run", action="store_true", help="run the updater in the foreground")
    parser.add_argument("--force", action="store_true", help="with --run: ignore the 24 hour rule")
    parser.add_argument("--dir", help="FFmpeg folder to manage (default: dependencies/ffmpeg)")
    args = parser.parse_args(argv)

    live = Path(args.dir) if args.dir else DEFAULT_DIR
    paths = Paths.for_dir(live)
    deps = real_deps()

    if args.resolve:
        print(resolve(live, paths, deps))
    elif args.status:
        print(format_status(paths, deps))
    elif args.check:
        print(check(paths, deps))
    else:
        print(run_update(paths, deps, force=args.force))
    return 0


if __name__ == "__main__":
    sys.exit(main())
