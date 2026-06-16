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

## Output defaults

FFMPEG-Kit's `$OutputDir` defaults to `%USERPROFILE%\Downloads` for all output (trims, merges, compresses, etc). Drop multiple files onto the launcher to merge them; drop one file to get the full menu (compress/landscape/cropfix/trim).

## Documentation rule for the hub

ffkit is David's personal setup - external users of sibling repos won't have it. **Never mention ffkit in any public-facing README** of repos that use it (including `dependencies/README.md`). Only these internal surfaces may mention it: `CLAUDE.md` and `dependencies/ffmpeg/README.md`. The hub behavior is transparent (silent fallback) - external users need no awareness of it.

## Key paths

| Path | Purpose |
|------|---------|
| `scripts/FFMPEG-Kit.bat` | Single drag-and-drop launcher for all tools (accepts 1+ files) |
| `scripts/FFMPEG-Kit.ps1` | Unified tool: compress / landscape blur-fill / remove black bars / trim clip(s) / merge files |
| `dependencies/ffmpeg/` | FFmpeg binary (gitignored) |
| `data/logs/` | Timestamped logs from each run |
