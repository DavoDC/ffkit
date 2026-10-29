# ffkit

FFmpeg tools and a shared FFmpeg location for projects cloned alongside it.

---

## Tools

### FFMPEG-Kit

One drag-and-drop launcher for all video operations.

**Usage:** Drag and drop a video file onto `scripts/FFMPEG-Kit.bat`, then choose:

| Option | What it does |
|--------|-------------|
| `[1]` Compress | Two-pass H.264 encode to a target file size (4 MB, 6 MB, 8 MB, custom) |
| `[2]` Portrait to landscape | Auto-removes black bars, scales to 1280x720 with blurred background fill |
| `[3]` Remove black bars | Auto-detects and crops embedded black bars, keeps original aspect ratio |
| `[4]` Trim clip(s) | Cuts one or more time ranges out of a single file (frame-accurate re-encode, visually lossless) |
| `[5]` Merge files | Joins 2+ dropped files into one (lossless stream copy when possible, falls back to re-encode) |
| `[6]` Convert to MP3 | Extracts the audio track to an MP3 file |

Drop one file to see the full menu. Drop several and you are asked once: merge them into one file, or run the per-file menu (without merge) on each file.

Trim and merge are separate tools by design - trim one clip out of a video, or merge already-trimmed clips, independently of each other.

Output defaults to `%USERPROFILE%\Downloads`. Set `$OutputDir` at the top of `FFMPEG-Kit.ps1` once to redirect all outputs to a different folder.

Logs saved to `data/logs/`. FFmpeg downloads automatically on first run.

### vidtools.py

A generic command-line helper around `ffmpeg` and `ffprobe` for checking video and making quick cuts. It uses Python 3.9+ and the standard library only. It finds `dependencies/ffmpeg/ffmpeg.exe` first, then `ffmpeg` on PATH. Every command prints plain text and exits 1 on failure. It never overwrites an existing file; it writes `name_1.ext` instead.

| Command | What it does | Example |
|---------|--------------|---------|
| `black` | Lists black segments as `start end` lines (`--min-duration`, `--threshold`) | `python scripts/vidtools.py black input.mp4` |
| `scenes` | Lists scene-change times in seconds (`--score`, `--after` skips early ones) | `python scripts/vidtools.py scenes input.mp4 --after 30` |
| `sheet` | Writes a tiled contact sheet JPG (`--every`, `--cols`, `--rows`) | `python scripts/vidtools.py sheet input.mp4 sheet.jpg --every 3` |
| `trim-black` | Cuts leading and trailing black, re-encodes, checks the output length (`--start`, `--end` override) | `python scripts/vidtools.py trim-black input.mp4 trimmed.mp4` |

---

## FFmpeg hub

ffkit acts as a shared FFmpeg location for any project cloned alongside it.

If `../ffkit/` exists, a project downloads FFmpeg into `ffkit/dependencies/ffmpeg/` and uses it from there - including ffkit's own tools. Once any project has run, all others find FFmpeg already present. If `ffkit` is absent, each project falls back to downloading into its own local folder. Projects stay fully standalone either way.

### Projects using this hub

- [FLAC_Flow](https://github.com/DavoDC/FLAC_Flow)
- [RivalsVidMaker](https://github.com/DavoDC/RivalsVidMaker)
- [CoverVidMaker](https://github.com/DavoDC/CoverVidMaker)
- [ytkit](https://github.com/DavoDC/ytkit)

---

## Background updates

FFmpeg goes stale, so ffkit can keep the shared binaries fresh without ever making a task wait. `scripts/ffkit_update.py` returns the current `ffmpeg.exe` straight away. If the last check was more than 24 hours ago, a detached background process looks up the latest release, downloads it, extracts it beside the live folder, runs `-version` on the new `ffmpeg.exe` as a smoke test, keeps the old files in `dependencies/ffmpeg.previous/`, and swaps each file in with `os.replace`. The next task picks up the new version.

A failed download or a failed smoke test never touches the working binaries. If `ffmpeg.exe` is in use (Windows locks running programs) the new files stay staged and the swap is retried a little later. A lock file keeps it to one updater at a time, and the time of the last check is recorded before the network call so a crash cannot cause a retry storm. Activity is logged to `data/logs/ffkit_update.log`. It needs Python 3 and nothing else; the PowerShell tools do not start it on their own, so trigger it from your own tooling or by hand:

```bash
python scripts/ffkit_update.py --status   # last check, stale or fresh, pending swap (no side effects)
python scripts/ffkit_update.py --check    # start the background updater if a check is due
python scripts/ffkit_update.py --run --force   # update now, in the foreground
```

---

## Requirements

- Windows
- PowerShell (built into Windows)
- Internet connection on first run (FFmpeg downloads once to `dependencies/ffmpeg/`)
- Python 3 (for the optional background updater and `vidtools.py`)
