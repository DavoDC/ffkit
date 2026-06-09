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

Output goes alongside the input file by default. Set `$OutputDir` at the top of `FFMPEG-Kit.ps1` once to redirect all outputs to a fixed folder (e.g. `Videos\Processed`).

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

## Requirements

- Windows
- PowerShell (built into Windows)
- Internet connection on first run (FFmpeg downloads once to `dependencies/ffmpeg/`)
