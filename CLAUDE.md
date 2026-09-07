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

FFMPEG-Kit's `$OutputDir` defaults to `%USERPROFILE%\Downloads` for all output (trims, merges, compresses, etc). Drop one file to get the full menu (compress/landscape/cropfix/trim/mp3). Drop multiple files and you're asked once: merge them into one file, or run separate per-file actions - separate shows the same per-file menu (minus merge) for each file, queues the jobs, runs them one at a time, then prints one consolidated results block. `-Action merge` (or any other `-Action` value) skips that question non-interactively and applies to every dropped file.

## Sibling repos that use ffkit's FFmpeg

- **ytkit** (`C:\Users\David\GitHubRepos\ytkit`) - yt-dlp audio/video downloader. Points its `config/config.json` `ffmpeg_dir` at ffkit's `dependencies/ffmpeg/`. Default output: MP3 highest quality. See ytkit's `CLAUDE.md` for the full download command.

## Documentation rule for the hub

ffkit is a personal setup - external users of sibling repos won't have it. **Never mention ffkit in any public-facing README** of repos that use it (unless that repo explicitly cross-references ffkit as a sibling tool). Only these internal surfaces may mention it by default: `CLAUDE.md` and `dependencies/ffmpeg/README.md`. The hub behavior is transparent (silent fallback) - external users need no awareness of it.

## Trim efficiency: fast (stream copy) vs precise (re-encode)

`-Action trim` defaults to `-TrimMode fast`: input-seek (`-ss` before `-i`) + `-c copy`, no re-encode.
For a simple cut (e.g. "give me everything from 20:55 onward" on an 8GB file) this takes seconds,
not minutes, because no frames are decoded/encoded - the container is just re-muxed. Cut lands on
the nearest keyframe at/before the requested time (usually within ~1-2s), not frame-exact.

Use `-TrimMode precise` only when the cut point must be frame-exact (e.g. trimming mid-scene for a
highlight reel) - it re-encodes with libx265, which is much slower on large files since ffmpeg has
to decode from the start of the file to seek accurately.

Blank end in `-ClipArgs` (e.g. `"20:55-"`) trims to end of file - no need to know/pass the duration.

Example: `.\FFMPEG-Kit.ps1 -InputFiles "video.mp4" -Action trim -ClipArgs "20:55-"`

## Key paths

| Path | Purpose |
|------|---------|
| `scripts/FFMPEG-Kit.bat` | Single drag-and-drop launcher for all tools (accepts 1+ files) |
| `scripts/FFMPEG-Kit.ps1` | Unified tool: compress / landscape blur-fill / remove black bars / trim clip(s) / merge files |
| `dependencies/ffmpeg/` | FFmpeg binary (gitignored) |
| `data/logs/` | Timestamped logs from each run |
