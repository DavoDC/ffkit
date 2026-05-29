# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Setting up repo structure and porting the compressor tool from WindowsFiles.

---

## Pending - Main Work

---

**Add sibling-check to 4 existing repos**

Each of these repos downloads FFmpeg independently. Add a sibling-check so they use ffkit's copy first, eliminating duplicate downloads.

Repos to update:
- `SBS_Download` - downloads FFmpeg if missing
- `FLAC_Flow` - downloads FFmpeg if missing
- `RivalsVidMaker` - downloads FFmpeg if missing
- `CoverVidMaker` - requires FFmpeg on PATH

Pattern to add in each repo (Python):

```python
import os

FFKIT_FFMPEG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ffkit', 'dependencies', 'ffmpeg', 'ffmpeg.exe')

def get_ffmpeg_path():
    if os.path.exists(FFKIT_FFMPEG):
        return os.path.abspath(FFKIT_FFMPEG)
    return download_ffmpeg_locally()  # existing fallback unchanged
```

Note: assumes ffkit is cloned as a sibling repo (same parent folder). Repos stay fully standalone - if ffkit is absent, they download their own copy as before.

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
