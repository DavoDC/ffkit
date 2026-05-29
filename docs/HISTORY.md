# History

Completed features and settled design decisions.

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
