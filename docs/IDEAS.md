# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Setting up repo structure and porting the compressor tool from WindowsFiles.

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

**CoverVidMaker - manual copy from ffkit**

CVM is C++ with a flat `dependencies/` structure and manual FFmpeg setup. Auto-sibling-check not implemented.

Action when setting up CVM: copy binaries from `../ffkit/dependencies/ffmpeg/` into `dependencies/` directly.

Future consideration: standardise CVM's deps structure to `dependencies/ffmpeg/` subfolder for consistency with the Python repos. Requires C++ code changes to reference updated path.

---

---

**Raphael machine - apply sibling-check and clean up local copies**

Blocked until holiday ends. When back: apply the same sibling-check changes to SBS_Download, FLAC_Flow, RivalsVidMaker on Raphael, then delete the local FFmpeg copies from each repo there.

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
