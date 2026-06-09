# History

Completed features and settled design decisions.

---

## FFMPEG-PortraitFix added

New tool: `scripts/portrait-fix/FFMPEG-PortraitFix.ps1` (+ .bat drag-and-drop launcher).

Drag a video onto the .bat, choose:
- `[1]` Remove black bars - auto-detect with cropdetect, crop-encode, copy audio (fast)
- `[2]` Landscape blur-fill - crops bars then scales to 1280x720 with blurred background fill (best for PC viewing of portrait/social media videos)

---

## Local FFmpeg copies deleted from 3 Python repos

SBS_Download and FLAC_Flow had no local copy remaining. RivalsVidMaker's `dependencies/ffmpeg/` deleted. All 3 repos now rely on ffkit's shared copy. Disk deduplication complete on E15.

---

## Sibling-check implemented in 3 Python repos

Added 2-line ffkit sibling-check to SBS_Download, FLAC_Flow, and RivalsVidMaker. Each repo now uses ffkit's `dependencies/ffmpeg/` when `../ffkit/` exists, falling back to its own local copy otherwise. CoverVidMaker is C++ with manual deps - documented in that repo's IDEAS.md instead.

---

## Repo creation and initial structure

- Created `ffkit` repo with standard folder layout (scripts/, dependencies/, data/, docs/)
- Ported FFMPEG-Compressor from WindowsFiles repo
- Compressor updated to use shared `dependencies/ffmpeg/` and `data/logs/`
- Sibling-check design agreed: path-only convention, no centralised download code

**Why "ffkit" and not ffmpeg-tools or ffmpeg-kit:**
`ffmpeg-tools` is generic (tools suffix adds nothing). `ffmpeg-kit` / `FFmpegKit` is taken - arthenica's archived iOS/Android SDK lives at that name, search results collide. `fflab` implies experimental. `ffkit` is short, the `ff` prefix signals FFmpeg clearly, and "kit" implies a curated ready-to-use collection without overpromising.
