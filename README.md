# ffkit

FFmpeg tools and a shared FFmpeg location for projects cloned alongside it.

---

## Tools

### FFMPEG-Compressor

Compress a video to a specific target file size using two-pass H.264 encoding.

**Usage:** Drag and drop a video file onto `scripts/compress/FFMPEG-Compressor.bat`

- Choose a target size: 4 MB, 6 MB, 8 MB, quarter of original, half of original, or custom
- Output saved next to the input file as `filename_Xmb.mp4`
- Logs saved to `data/logs/`

FFmpeg is downloaded automatically on first run.

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
