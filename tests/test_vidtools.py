import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
import vidtools as vt

FFMPEG = "FAKE-ffmpeg"
FFPROBE = "FAKE-ffprobe"

BLACKDETECT_STDERR = """\
ffmpeg version 7.0 Copyright (c) 2000-2024 the FFmpeg developers
  Duration: 00:01:00.00, start: 0.000000, bitrate: 2500 kb/s
[blackdetect @ 0000021b3c1e4a40] black_start:0 black_end:2.52 black_duration:2.52
[blackdetect @ 0000021b3c1e4a40] black_start:14.04 black_end:14.6 black_duration:0.56
[blackdetect @ 0000021b3c1e4a40] black_start:58.2 black_duration:1.8
Output #0, null, to 'pipe:':
"""

SHOWINFO_STDERR = """\
[Parsed_showinfo_1 @ 000001f0a2c0] n:   0 pts:  40960 pts_time:1.70667 duration:   1024 dts:  40960
[Parsed_showinfo_1 @ 000001f0a2c0] n:   1 pts: 332800 pts_time:12.5 duration:   1024 dts: 332800
[Parsed_showinfo_1 @ 000001f0a2c0] n:   2 pts: 900000 pts_time:31.25 duration:   1024 dts: 900000
"""


class Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class Fake:
    """Injected process boundary. Records argv, never runs ffmpeg."""

    def __init__(self, stderr="", probes=(), rc=0, write=True):
        self.stderr = stderr
        self.probes = list(probes)
        self.rc = rc
        self.write = write
        self.calls = []

    def __call__(self, args):
        self.calls.append(list(args))
        if args[0] == FFPROBE:
            return Result(0, self.probes.pop(0), "")
        if args[-1] != "-" and self.write:
            Path(args[-1]).write_bytes(b"x" * 100)
        return Result(self.rc, "", self.stderr)


# ---- pure parsers -----------------------------------------------------------

def test_parse_blackdetect_reads_start_end_and_duration_only_tail():
    assert vt.parse_blackdetect(BLACKDETECT_STDERR) == [(0.0, 2.52), (14.04, 14.6), (58.2, 60.0)]


def test_parse_blackdetect_empty_when_no_black():
    assert vt.parse_blackdetect("Stream mapping:\nOutput #0, null\n") == []


def test_parse_scene_times_reads_pts_time_in_order():
    assert vt.parse_scene_times(SHOWINFO_STDERR) == [1.70667, 12.5, 31.25]


def test_parse_scene_times_ignores_non_numeric_pts():
    assert vt.parse_scene_times("pts_time:nan\n") == []


def test_parse_duration_reads_ffprobe_value():
    assert vt.parse_duration("59.972000\n") == pytest.approx(59.972)


@pytest.mark.parametrize("text", ["N/A", "", "garbage"])
def test_parse_duration_returns_none_for_bad_output(text):
    assert vt.parse_duration(text) is None


def test_keep_range_trims_leading_and_trailing_black():
    segs = [(0.0, 2.52), (14.04, 14.6), (58.2, 60.0)]
    assert vt.keep_range(segs, 60.0) == (2.52, 58.2)


def test_keep_range_no_black_keeps_everything():
    assert vt.keep_range([], 60.0) == (0.0, 60.0)


def test_keep_range_ignores_black_in_the_middle():
    assert vt.keep_range([(14.04, 14.6)], 60.0) == (0.0, 60.0)


def test_keep_range_explicit_start_overrides_detected_lead():
    assert vt.keep_range([(0.0, 2.52)], 60.0, start=5) == (5, 60.0)


def test_keep_range_explicit_end_overrides_detected_tail():
    assert vt.keep_range([(58.2, 60.0)], 60.0, end=30) == (0.0, 30)


def test_keep_range_rejects_empty_range():
    with pytest.raises(ValueError):
        vt.keep_range([(0.0, 60.0)], 60.0)


def test_keep_range_rejects_start_after_end():
    with pytest.raises(ValueError):
        vt.keep_range([], 60.0, start=40, end=10)


def test_unique_path_keeps_free_name(tmp_path):
    p = tmp_path / "out.mp4"
    assert vt.unique_path(p) == p


def test_unique_path_numbers_taken_names(tmp_path):
    (tmp_path / "out.mp4").write_bytes(b"x")
    assert vt.unique_path(tmp_path / "out.mp4") == tmp_path / "out_1.mp4"
    (tmp_path / "out_1.mp4").write_bytes(b"x")
    assert vt.unique_path(tmp_path / "out.mp4") == tmp_path / "out_2.mp4"


def test_unique_path_without_suffix(tmp_path):
    (tmp_path / "clip").write_bytes(b"x")
    assert vt.unique_path(tmp_path / "clip") == tmp_path / "clip_1"


def test_default_run_hides_console_window(monkeypatch):
    seen = {}

    def fake_run(args, **kwargs):
        seen.update(kwargs)
        return None

    monkeypatch.setattr(vt.subprocess, "run", fake_run)
    vt.default_run(["ffmpeg", "-version"])
    assert "creationflags" in seen


# ---- binary lookup ----------------------------------------------------------

def test_find_ffmpeg_prefers_repo_local_binary(tmp_path):
    local = tmp_path / "dependencies" / "ffmpeg" / "ffmpeg.exe"
    local.parent.mkdir(parents=True)
    local.write_bytes(b"x")
    assert vt.find_ffmpeg(tmp_path, which=lambda name: "/usr/bin/ffmpeg") == str(local)


def test_find_ffmpeg_falls_back_to_path(tmp_path):
    assert vt.find_ffmpeg(tmp_path, which=lambda name: "/usr/bin/ffmpeg") == "/usr/bin/ffmpeg"


def test_find_ffmpeg_none_when_missing(tmp_path):
    assert vt.find_ffmpeg(tmp_path, which=lambda name: None) is None


def test_find_ffprobe_falls_back_to_path(tmp_path):
    assert vt.find_ffprobe(tmp_path, which=lambda name: "/usr/bin/ffprobe") == "/usr/bin/ffprobe"


def test_find_ffprobe_none_when_missing(tmp_path):
    assert vt.find_ffprobe(tmp_path, which=lambda name: None) is None


# ---- subcommands ------------------------------------------------------------

def run_main(argv, fake, capsys):
    code = vt.main(argv, run=fake, ffmpeg=FFMPEG, ffprobe=FFPROBE)
    out = capsys.readouterr().out
    return code, out


def test_black_prints_segments_and_uses_blackdetect(capsys):
    fake = Fake(stderr=BLACKDETECT_STDERR)
    code, out = run_main(["black", "input.mp4", "--min-duration", "0.5", "--threshold", "0.2"], fake, capsys)
    assert code == 0
    assert out.splitlines() == ["0.000 2.520", "14.040 14.600", "58.200 60.000"]
    argv = fake.calls[0]
    assert argv[0] == FFMPEG
    assert "blackdetect=d=0.5:pix_th=0.2" in argv
    assert argv[-4:] == ["-an", "-f", "null", "-"]


def test_black_exit_1_on_ffmpeg_failure(capsys):
    fake = Fake(stderr="input.mp4: No such file", rc=1)
    code, _ = run_main(["black", "missing.mp4"], fake, capsys)
    assert code == 1


def test_scenes_prints_all_times(capsys):
    fake = Fake(stderr=SHOWINFO_STDERR)
    code, out = run_main(["scenes", "input.mp4", "--score", "0.4"], fake, capsys)
    assert code == 0
    assert out.splitlines() == ["1.707", "12.500", "31.250"]
    assert "select='gt(scene,0.4)',showinfo" in fake.calls[0]


def test_scenes_after_filters_earlier_times(capsys):
    fake = Fake(stderr=SHOWINFO_STDERR)
    code, out = run_main(["scenes", "input.mp4", "--after", "10"], fake, capsys)
    assert code == 0
    assert out.splitlines() == ["12.500", "31.250"]


def test_sheet_writes_tiled_jpg(tmp_path, capsys):
    fake = Fake()
    out_path = tmp_path / "sheet.jpg"
    code, out = run_main(["sheet", "input.mp4", str(out_path), "--every", "2", "--cols", "3", "--rows", "2"], fake, capsys)
    assert code == 0
    assert out_path.exists()
    assert str(out_path) in out
    argv = fake.calls[0]
    assert "fps=1/2,scale=240:-1,tile=3x2" in argv
    assert argv[argv.index("-frames:v") + 1] == "1"
    assert argv[argv.index("-q:v") + 1] == "8"


def test_sheet_exit_1_when_file_not_written(tmp_path, capsys):
    fake = Fake(write=False)
    code, _ = run_main(["sheet", "input.mp4", str(tmp_path / "sheet.jpg")], fake, capsys)
    assert code == 1


def test_sheet_never_overwrites_existing_file(tmp_path, capsys):
    existing = tmp_path / "sheet.jpg"
    existing.write_bytes(b"old")
    fake = Fake()
    code, _ = run_main(["sheet", "input.mp4", str(existing)], fake, capsys)
    assert code == 0
    assert existing.read_bytes() == b"old"
    assert (tmp_path / "sheet_1.jpg").exists()


def test_trim_black_cuts_detected_black_and_verifies(tmp_path, capsys):
    # probes: input duration 60.0, then output duration 55.8 (keep range 2.52..58.2)
    fake = Fake(stderr=BLACKDETECT_STDERR, probes=["60.0\n", "55.8\n"])
    out_path = tmp_path / "clip.mp4"
    code, out = run_main(["trim-black", "input.mp4", str(out_path)], fake, capsys)
    assert code == 0
    assert out_path.exists()
    assert str(out_path) in out
    assert "55.8" in out
    enc = fake.calls[2]
    assert enc[0] == FFMPEG
    assert enc[enc.index("-ss") + 1] == "2.520"
    assert enc[enc.index("-to") + 1] == "58.200"
    assert "libx264" in enc and "aac" in enc


def test_trim_black_respects_explicit_start_end(tmp_path, capsys):
    fake = Fake(stderr="", probes=["60.0\n", "10.0\n"])
    code, _ = run_main(["trim-black", "input.mp4", str(tmp_path / "c.mp4"), "--start", "5", "--end", "15"], fake, capsys)
    assert code == 0
    enc = fake.calls[1]
    assert enc[enc.index("-ss") + 1] == "5.000"
    assert enc[enc.index("-to") + 1] == "15.000"


def test_trim_black_picks_unused_output_name(tmp_path, capsys):
    (tmp_path / "clip.mp4").write_bytes(b"old")
    fake = Fake(stderr="", probes=["60.0\n", "60.0\n"])
    code, _ = run_main(["trim-black", "input.mp4", str(tmp_path / "clip.mp4")], fake, capsys)
    assert code == 0
    assert (tmp_path / "clip.mp4").read_bytes() == b"old"
    assert (tmp_path / "clip_1.mp4").exists()


def test_trim_black_exit_1_when_duration_off(tmp_path, capsys):
    fake = Fake(stderr="", probes=["60.0\n", "30.0\n"])
    code, _ = run_main(["trim-black", "input.mp4", str(tmp_path / "c.mp4")], fake, capsys)
    assert code == 1


def test_trim_black_exit_1_when_input_duration_unknown(tmp_path, capsys):
    fake = Fake(stderr="", probes=["N/A\n"])
    code, _ = run_main(["trim-black", "input.mp4", str(tmp_path / "c.mp4")], fake, capsys)
    assert code == 1
