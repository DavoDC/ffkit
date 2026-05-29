# ffkit

Practical FFmpeg tools, and a shared FFmpeg location for sibling repos.

---

## What ffkit does

**1. Tools** - Ready-to-use scripts for common FFmpeg tasks (compress, trim, convert).

**2. FFmpeg hub** - A single place for FFmpeg to live on disk, shared across multiple repos.
Instead of every repo downloading its own copy, they check for ffkit first.

---

## FFmpeg hub - how it works

Any repo that uses FFmpeg can check whether ffkit exists as a sibling repo.
If it does, that repo downloads FFmpeg into ffkit's `dependencies/ffmpeg/` folder and uses it from there.
If ffkit is not present, the repo falls back to downloading FFmpeg into its own local folder as normal.

The check is on the ffkit repo folder itself - not on whether FFmpeg is already downloaded.
This means the first repo to run will trigger the download into ffkit, and all subsequent repos find it already there.

Repos stay fully standalone. ffkit being absent just means each repo handles its own FFmpeg copy.

### Repos using this hub

- [SBS_Download](https://github.com/DavoDC/SBS_Download)
- [FLAC_Flow](https://github.com/DavoDC/FLAC_Flow)
- [RivalsVidMaker](https://github.com/DavoDC/RivalsVidMaker)
- [CoverVidMaker](https://github.com/DavoDC/CoverVidMaker)

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

## Requirements

- Windows
- PowerShell (built into Windows)
- Internet connection on first run (FFmpeg downloads once to `dependencies/ffmpeg/`)
