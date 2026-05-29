# ffkit

Practical FFmpeg tools - compress, trim, convert. FFmpeg is downloaded automatically on first use.

---

## Tools

### FFMPEG-Compressor

Compress a video to a specific target file size using two-pass H.264 encoding.

**Usage:** Drag and drop a video file onto `scripts/compress/FFMPEG-Compressor.bat`

- Choose a target size: 4 MB, 6 MB, 8 MB, quarter of original, half of original, or custom
- Output saved next to the input file as `filename_Xmb.mp4`
- Logs saved to `data/logs/`

FFmpeg is downloaded automatically if not already present (requires internet on first run).

---

## Requirements

- Windows
- PowerShell (built into Windows)
- Internet connection on first run (FFmpeg auto-downloads once to `dependencies/ffmpeg/`)
