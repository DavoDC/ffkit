# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Active development - adding more tools to `scripts/`.

---

## Pending - Main Work

---

---

**Raphael machine - pull repos and delete local FFmpeg copies**

Blocked until holiday ends. When back: pull latest on SBS_Download, FLAC_Flow, and RivalsVidMaker (sibling-check already in main), then delete the local `dependencies/ffmpeg/` copy from each repo.

---

## Lower Priority / Future

---

**Streamline terminal output - raw ffmpeg logs still full in log file**

Raised 2026-07-11: the terminal currently prints the full raw ffmpeg/ffprobe
stderr stream for each pass (codec config dump, per-frame libx264 stats,
weighted-frame tables, etc.) - correct info, way too much of it for a
terminal a human is watching live. Keep the terminal to the tool's own
progress lines (locating ffmpeg, analysing duration, target size, pass
1/2 progress, final results) and suppress/collapse the raw ffmpeg
console output there. **The full raw ffmpeg output must still go
in the log file** (`data/logs/ffkit_*.log`) unchanged - this is a
terminal-display change only, not a reduction in what's captured.
Likely implementation: redirect ffmpeg's own stdout/stderr to the log
file (already being written) instead of also letting it pass through to
the console, and print only the script's own summary lines to terminal.

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
