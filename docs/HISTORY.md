# History

Completed features and settled design decisions.

---

## Consolidated to FFMPEG-Kit

All tools merged into `scripts/FFMPEG-Kit.bat` + `scripts/FFMPEG-Kit.ps1`. Deleted the separate `compress/` and `portrait-fix/` subfolders.

One drag target, three operations:
- `[1]` Compress to target size (two-pass H.264)
- `[2]` Portrait to landscape blur-fill (1280x720, removes black bars)
- `[3]` Remove black bars only

Set `$OutputDir` at top of `FFMPEG-Kit.ps1` to redirect outputs away from the input folder.

---

## Trim tool: fast stream-copy mode added

Raised 2026-07-14: trimming the last chunk off an 8GB video with the original re-encode-only
`Invoke-Trim` would have taken many minutes (output seeking - decodes from file start). Added
`-TrimMode fast` (default): input seeking (`-ss` before `-i`) + `-c copy`, no re-encode - same
8GB trim now takes ~18s. Also: blank end in a clip arg (e.g. `"20:55-"`) now means "to end of
file", so duration doesn't need to be looked up first. `-TrimMode precise` keeps the old
re-encode behavior for when frame-exact cuts matter more than speed.

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
