# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Setting up repo structure and porting the compressor tool from WindowsFiles.

---

## Pending - Main Work

---

**Add sibling-check to 4 existing repos**

Each repo currently downloads FFmpeg into its own folder. Update each one to check for ffkit first.

**Logic to implement in each repo (language-agnostic):**
- Check if the ffkit repo folder exists as a sibling (`../ffkit/`)
- If yes: download FFmpeg into ffkit's `dependencies/ffmpeg/` (if not already there), use it from there
- If no: download FFmpeg into the repo's own local folder as before (existing behaviour unchanged)
- The check is on the repo folder, not the binary - so the first repo to run triggers the download into ffkit

**Per-repo steps:**
1. Update the FFmpeg finder to implement the above logic
2. Delete the existing local FFmpeg copy from that repo (freeing disk space)
3. Test both paths: with ffkit sibling present, and without

Repos to update:
- `SBS_Download` - has its own download logic (E15 first)
- `FLAC_Flow` - has its own download logic (E15 first)
- `RivalsVidMaker` - has its own download logic (E15 first)
- `CoverVidMaker` - currently requires FFmpeg on PATH, needs download logic added (E15 first)
- Raphael machine: blocked until holiday ends - do all 4 repos there as a batch when back

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
