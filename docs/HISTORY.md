# History

Completed features and settled design decisions.

---

## Multi-file batch flows - per-file actions, not just forced merge

From /think + /aristotle (2026-09-07), implemented same day. Previously N>1
files silently forced a merge with zero prompting. Now `FFMPEG-Kit.ps1` asks
ONE bootstrapping question when multiple files are dropped: "Merge these into
one file, or separate actions per file?" Merge picks up the existing
`Invoke-Merge` unchanged. Separate loops file-by-file, shows the same
single-file menu (options 1-4, 6 - no merge per-file), and collects
`{file, action, params}` into a job queue with zero ffmpeg calls (plan
phase). The queue then runs sequentially - no parallel ffmpeg execution,
still one terminal - through the same `Invoke-*` functions used for N=1
(execute phase), and prints one consolidated results block at the end
(report phase) instead of scattered per-job output.

`-Action merge` (or `"5"`) skips the question non-interactively. Any other
`-Action` value for N>1 also skips the question and applies that one action
to every dropped file with no per-file prompts, so existing scripted/Claude
`-Action` usage (previously silently only touching file 1) keeps working -
and now actually processes every file.

Required refactor: `Invoke-Compress`, `Invoke-LandscapeFill`, `Invoke-CropFix`,
`Invoke-Trim`, `Invoke-ConvertMp3`, and `Get-CropParams` now take the file,
output location, and tool-specific params as explicit parameters instead of
closing over module-level globals - the same function body runs for N=1 and
for each queued batch job. Each of the five tool functions also gained a
`-Quiet` switch: unset (N=1, the default) prints exactly as before; set
(batch execute phase) suppresses the per-job results printing and instead
returns a `{Success, ErrorMessage, Outputs, Lines}` object that MAIN collects
into the consolidated report. Sub-prompts (target-size menu for compress,
clip-list entry for trim) were split into standalone helpers
(`Read-TargetMBInteractive`, `Read-ClipsInteractive` / `Get-ClipsFromArgs`) so
the batch plan phase can ask them once per file up front, reusing the exact
same prompt text as the N=1 interactive fallback.

**Acceptance test passed**: ran `-Action compress -TargetMB 1` on the same
synthetic test video before and after the refactor (via a checked-out copy of
the pre-refactor script) and diffed the two transcripts after normalizing
only timestamps, log filenames, and encode-speed multipliers (all of which
vary run-to-run) - byte-identical. Also smoke-tested N=1 trim and landscape,
N>1 merge (`-Action merge`), N>1 separate-noninteractive (`-Action mp3`
applied to 2 files), and the full interactive separate flow (2 files, mixed
actions: compress on file 1, trim on file 2, one consolidated results block).

Deliberately not built: parallel ffmpeg execution (rejected in the original
design - two CPU-bound encodes fight over the same cores, no GPU path wired
up), and a generic verbosity/config system.

---

## Consolidated to FFMPEG-Kit

All tools merged into `scripts/FFMPEG-Kit.bat` + `scripts/FFMPEG-Kit.ps1`. Deleted the separate `compress/` and `portrait-fix/` subfolders.

One drag target, three operations:
- `[1]` Compress to target size (two-pass H.264)
- `[2]` Portrait to landscape blur-fill (1280x720, removes black bars)
- `[3]` Remove black bars only

Set `$OutputDir` at top of `FFMPEG-Kit.ps1` to redirect outputs away from the input folder.

---

## Trim tool: fast stream-copy mode added

Raised 2026-07-14: trimming the last chunk off an 8GB video with the original re-encode-only
`Invoke-Trim` would have taken many minutes (output seeking - decodes from file start). Added
`-TrimMode fast` (default): input seeking (`-ss` before `-i`) + `-c copy`, no re-encode - same
8GB trim now takes ~18s. Also: blank end in a clip arg (e.g. `"20:55-"`) now means "to end of
file", so duration doesn't need to be looked up first. `-TrimMode precise` keeps the old
re-encode behavior for when frame-exact cuts matter more than speed.

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

**Why "ffkit" and not ffmpeg-tools or ffmpeg-kit:**
`ffmpeg-tools` is generic (tools suffix adds nothing). `ffmpeg-kit` / `FFmpegKit` is taken - arthenica's archived iOS/Android SDK lives at that name, search results collide. `fflab` implies experimental. `ffkit` is short, the `ff` prefix signals FFmpeg clearly, and "kit" implies a curated ready-to-use collection without overpromising.
