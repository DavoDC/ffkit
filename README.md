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
| `[5]` Merge files | Drag and drop 2+ files onto the launcher to join them into one (lossless stream copy when possible, falls back to re-encode) |

Trim and merge are separate tools by design - trim one clip out of a video, or merge already-trimmed clips, independently of each other.

Output defaults to `%USERPROFILE%\Downloads`. Set `$OutputDir` at the top of `FFMPEG-Kit.ps1` once to redirect all outputs to a different folder.

Logs saved to `data/logs/`. FFmpeg downloads automatically on first run.

---

## FFmpeg hub

ffkit acts as a shared FFmpeg location for any project cloned alongside it.

If `../ffkit/` exists, a project downloads FFmpeg into `ffkit/dependencies/ffmpeg/` and uses it from there - including ffkit's own tools. Once any project has run, all others find FFmpeg already present. If `ffkit` is absent, each project falls back to downloading into its own local folder. Projects stay fully standalone either way.

### Projects using this hub

- [SBS_Download](https://github.com/DavoDC/SBS_Download)
- [FLAC_Flow](https://github.com/DavoDC/FLAC_Flow)
- [RivalsVidMaker](https://github.com/DavoDC/RivalsVidMaker)
- [CoverVidMaker](https://github.com/DavoDC/CoverVidMaker)

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
- Python 3 (only for the optional background updater)
