# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Setting up repo structure and porting the compressor tool from WindowsFiles.

---

## Pending - Main Work

---

**Add sibling-check to 4 existing repos**

Each of these repos downloads FFmpeg independently. Add a sibling-check so they use ffkit's copy first, then delete their own local FFmpeg copy to free disk space.

Per-repo steps:
1. Add sibling-check to FFmpeg finder (check `../ffkit/dependencies/ffmpeg/ffmpeg.exe` first)
2. Delete the local `ffmpeg/` or `dependencies/ffmpeg/` copy from that repo
3. Test: with and without ffkit sibling present

Repos to update:
- `SBS_Download` - downloads FFmpeg if missing (E15 only - do first)
- `FLAC_Flow` - downloads FFmpeg if missing (E15 only)
- `RivalsVidMaker` - downloads FFmpeg if missing (E15 only)
- `CoverVidMaker` - requires FFmpeg on PATH (E15 only)
- Raphael machine: blocked until holiday ends - do all 4 repos there as a batch when back

Note: repos stay fully standalone - if ffkit is absent they download their own copy. The sibling-check is a path check only, no code dependency on ffkit.

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
