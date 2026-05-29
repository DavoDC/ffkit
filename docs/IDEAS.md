# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Confirming sibling-check works across 3 Python repos, then deleting their local FFmpeg copies.

---

## Pending - Main Work

---

**Sibling-check done - delete local FFmpeg copies from 3 Python repos**

SBS_Download, FLAC_Flow, and RivalsVidMaker now check for ffkit first. Each still has a local FFmpeg copy on disk from before the change. Delete those to complete the disk deduplication.

Per repo:
1. Confirm the sibling-check is working (run the tool, verify it uses ffkit's FFmpeg)
2. Delete the local `dependencies/ffmpeg/` folder from that repo

Repos:
- `SBS_Download` - delete `dependencies/ffmpeg/` once confirmed working
- `FLAC_Flow` - delete `dependencies/ffmpeg/` once confirmed working
- `RivalsVidMaker` - delete the locally downloaded FFmpeg copy (config-driven, now resolved via ffkit)

---

---

**Raphael machine - pull repos and delete local FFmpeg copies**

Blocked until holiday ends. When back: pull latest on SBS_Download, FLAC_Flow, and RivalsVidMaker (sibling-check already in main), then delete the local `dependencies/ffmpeg/` copy from each repo.

---

## Lower Priority / Future

---

**Additional tools**

Further scripts to add to `scripts/` as needed:
- Trim/cut a video by timestamps
- Convert between formats (mp4/mkv/webm/gif)
- Extract audio from video
- Batch compress a folder of videos

---

## See Also

- `docs/HISTORY.md` - completed features, settled design decisions
