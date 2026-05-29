# ffkit

General-purpose FFmpeg scripts and utilities.

## Structure

- `scripts/` - end-user tools (drag-and-drop launchers + PowerShell/Python)
- `dependencies/ffmpeg/` - FFmpeg binary (gitignored, auto-downloaded on first run)
- `data/logs/` - runtime logs from script runs
- `docs/IDEAS.md` - pending work
- `docs/HISTORY.md` - completed work

## FFmpeg location

Tools download FFmpeg to `dependencies/ffmpeg/` automatically if not on PATH.
This is the shared location - sibling repos check here first before downloading their own copy.

## Key paths

| Path | Purpose |
|------|---------|
| `scripts/compress/` | FFMPEG-Compressor - drag and drop to compress video to target size |
| `dependencies/ffmpeg/` | FFmpeg binary (gitignored) |
| `data/logs/` | Timestamped logs from each run |
