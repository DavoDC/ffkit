#!/usr/bin/env python3
"""Generic video helper CLI around ffmpeg and ffprobe.

Stdlib only, Python 3.9+. Subcommands print plain text and exit 1 on failure:

  black       list black-frame segments (blackdetect)
  scenes      list scene-change timestamps (showinfo)
  sheet       write a tiled contact sheet (JPG)
  trim-black  cut leading and trailing black, re-encode, verify the duration

ffmpeg is looked up at dependencies/ffmpeg/ffmpeg.exe beside the repo root,
then on PATH. The `run` callable is injected so tests never start a process.
"""
import argparse
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EDGE_TOL = 0.1          # seconds: a black segment this close to 0 or the end counts as leading/trailing
DURATION_TOL = 0.2      # seconds: allowed gap between expected and verified output length
DEFAULT_MIN_BLACK = 0.1
DEFAULT_PIX_TH = 0.1
DEFAULT_SCORE = 0.5

BLACK_RE = re.compile(
    r"black_start:([0-9.]+)(?:\s+black_end:([0-9.]+))?(?:\s+black_duration:([0-9.]+))?"
)
SCENE_RE = re.compile(r"pts_time:([0-9]+(?:\.[0-9]+)?)")


class ToolError(RuntimeError):
    """A failed ffmpeg/ffprobe step; main() prints it and exits 1."""


def default_run(args):
    """Run a process and capture output. `run` returns an object with returncode/stdout/stderr."""
    # CREATE_NO_WINDOW keeps the child from flashing a console when launched under pythonw.
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace",
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


# ---- binary lookup ---------------------------------------------------------

def find_ffmpeg(repo_root=REPO_ROOT, which=shutil.which):
    local = Path(repo_root) / "dependencies" / "ffmpeg" / "ffmpeg.exe"
    if local.exists():
        return str(local)
    return which("ffmpeg")


def find_ffprobe(repo_root=REPO_ROOT, which=shutil.which):
    local = Path(repo_root) / "dependencies" / "ffmpeg" / "ffprobe.exe"
    if local.exists():
        return str(local)
    return which("ffprobe")


# ---- pure parsers and helpers ----------------------------------------------

def parse_blackdetect(stderr):
    """Return [(start, end)] from blackdetect log lines. A tail line with only black_duration gets end = start + duration."""
    segments = []
    for m in BLACK_RE.finditer(stderr):
        start = float(m.group(1))
        if m.group(2) is not None:
            end = float(m.group(2))
        elif m.group(3) is not None:
            end = round(start + float(m.group(3)), 6)
        else:
            continue
        segments.append((start, end))
    return segments


def parse_scene_times(stderr):
    """Return the pts_time values reported by showinfo, in log order."""
    return [float(t) for t in SCENE_RE.findall(stderr)]


def parse_duration(text):
    """Parse one ffprobe duration value. Returns None when it is not a finite number."""
    try:
        value = float(text.strip())
    except ValueError:
        return None
    if not math.isfinite(value) or value < 0:
        return None
    return value


def keep_range(segments, duration, start=None, end=None):
    """Return (start, end) to keep. Explicit start/end win; otherwise a black segment at 0 is cut from the front
    and one ending at the duration is cut from the back. Mid-clip black is kept."""
    lead = [e for s, e in segments if s <= EDGE_TOL]
    tail = [s for s, e in segments if e >= duration - EDGE_TOL]
    a = start if start is not None else (max(lead) if lead else 0.0)
    b = end if end is not None else (min(tail) if tail else duration)
    if not (0 <= a < b <= duration):
        raise ValueError(f"invalid keep range {a:.3f}-{b:.3f} for duration {duration:.3f}")
    return a, b


def unique_path(path):
    """Return path, or name_1.ext, name_2.ext, ... so an existing file is never overwritten."""
    p = Path(path)
    if not p.exists():
        return p
    n = 1
    while True:
        candidate = p.with_name(f"{p.stem}_{n}{p.suffix}")
        if not candidate.exists():
            return candidate
        n += 1


# ---- ffmpeg/ffprobe command builders ---------------------------------------

def black_argv(ffmpeg, video, min_duration, threshold):
    return [ffmpeg, "-hide_banner", "-i", video,
            "-vf", f"blackdetect=d={min_duration:g}:pix_th={threshold:g}",
            "-an", "-f", "null", "-"]


def detect_black(run, ffmpeg, video, min_duration=DEFAULT_MIN_BLACK, threshold=DEFAULT_PIX_TH):
    res = run(black_argv(ffmpeg, video, min_duration, threshold))
    if res.returncode != 0:
        raise ToolError(f"blackdetect failed: {res.stderr.strip()[-300:]}")
    return parse_blackdetect(res.stderr)


def probe_duration(run, ffprobe, path):
    argv = [ffprobe, "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", str(path)]
    res = run(argv)
    if res.returncode != 0:
        raise ToolError(f"ffprobe failed for {path}")
    value = parse_duration(res.stdout)
    if value is None:
        raise ToolError(f"could not read duration of {path}")
    return value


# ---- subcommands ------------------------------------------------------------

def cmd_black(args, run, ffmpeg, ffprobe):
    for start, end in detect_black(run, ffmpeg, args.video, args.min_duration, args.threshold):
        print(f"{start:.3f} {end:.3f}")
    return 0


def cmd_scenes(args, run, ffmpeg, ffprobe):
    res = run([ffmpeg, "-hide_banner", "-i", args.video,
               "-vf", f"select='gt(scene,{args.score:g})',showinfo", "-an", "-f", "null", "-"])
    if res.returncode != 0:
        raise ToolError(f"scene detection failed: {res.stderr.strip()[-300:]}")
    for t in parse_scene_times(res.stderr):
        if args.after is None or t > args.after:
            print(f"{t:.3f}")
    return 0


def cmd_sheet(args, run, ffmpeg, ffprobe):
    out = unique_path(args.out)
    res = run([ffmpeg, "-hide_banner", "-i", args.video,
               "-vf", f"fps=1/{args.every:g},scale=240:-1,tile={args.cols}x{args.rows}",
               "-frames:v", "1", "-q:v", "8", str(out)])
    if res.returncode != 0:
        raise ToolError(f"sheet failed: {res.stderr.strip()[-300:]}")
    if not out.exists() or out.stat().st_size == 0:
        raise ToolError(f"sheet was not written: {out}")
    print(f"{out} {out.stat().st_size} bytes")
    return 0


def cmd_trim_black(args, run, ffmpeg, ffprobe):
    if not ffprobe:
        raise ToolError("ffprobe not found (dependencies/ffmpeg/ffprobe.exe or PATH)")
    duration = probe_duration(run, ffprobe, args.video)
    segments = []
    if args.start is None or args.end is None:
        segments = detect_black(run, ffmpeg, args.video)
    start, end = keep_range(segments, duration, args.start, args.end)
    out = unique_path(args.out)
    res = run([ffmpeg, "-hide_banner", "-i", args.video,
               "-ss", f"{start:.3f}", "-to", f"{end:.3f}",
               "-c:v", "libx264", "-c:a", "aac", str(out)])
    if res.returncode != 0:
        raise ToolError(f"encode failed: {res.stderr.strip()[-300:]}")
    if not out.exists():
        raise ToolError(f"output was not written: {out}")
    expected = end - start
    got = probe_duration(run, ffprobe, out)
    if abs(got - expected) > DURATION_TOL:
        raise ToolError(f"duration mismatch: expected {expected:.3f}s, got {got:.3f}s")
    print(f"{out} {got:.3f}s")
    return 0


COMMANDS = {
    "black": cmd_black,
    "scenes": cmd_scenes,
    "sheet": cmd_sheet,
    "trim-black": cmd_trim_black,
}


def build_parser():
    parser = argparse.ArgumentParser(description="ffmpeg helper: black detection, scenes, contact sheets, black trim.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("black", help="list black segments as 'start end' lines")
    p.add_argument("video")
    p.add_argument("--min-duration", type=float, default=DEFAULT_MIN_BLACK)
    p.add_argument("--threshold", type=float, default=DEFAULT_PIX_TH)

    p = sub.add_parser("scenes", help="list scene-change times in seconds")
    p.add_argument("video")
    p.add_argument("--after", type=float, default=None)
    p.add_argument("--score", type=float, default=DEFAULT_SCORE)

    p = sub.add_parser("sheet", help="write a tiled contact sheet JPG")
    p.add_argument("video")
    p.add_argument("out")
    p.add_argument("--every", type=float, default=3)
    p.add_argument("--cols", type=int, default=5)
    p.add_argument("--rows", type=int, default=4)

    p = sub.add_parser("trim-black", help="cut leading/trailing black and re-encode")
    p.add_argument("video")
    p.add_argument("out")
    p.add_argument("--start", type=float, default=None)
    p.add_argument("--end", type=float, default=None)
    return parser


def main(argv=None, run=None, ffmpeg=None, ffprobe=None):
    args = build_parser().parse_args(argv)
    run = run or default_run
    ffmpeg = ffmpeg or find_ffmpeg()
    ffprobe = ffprobe or find_ffprobe()
    if not ffmpeg:
        print("ERROR: ffmpeg not found (dependencies/ffmpeg/ffmpeg.exe or PATH)", file=sys.stderr)
        return 1
    try:
        return COMMANDS[args.command](args, run, ffmpeg, ffprobe)
    except (OSError, ValueError, ToolError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
