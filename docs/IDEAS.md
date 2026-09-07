# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Active development - adding more tools to `scripts/`.

---

## Pending - Main Work

---

**BUG: multi-file drag-drop silently mis-binds args**

`FFMPEG-Kit.bat` passes dropped files as bare positional args (`%*`).
`$InputFiles` (string[]) is not the last positional parameter in
`FFMPEG-Kit.ps1` (`$Action`, `$TargetMB`, etc. follow it), so PowerShell's
binder assigns only the *first* file to `-InputFiles` and shoves the
*second* file path straight into `-Action` - producing "Action:
...mp4 (from -Action argument)" / "Invalid choice." on any 2+ file drop.
Fix: add `[Parameter(ValueFromRemainingArguments=$true)]` to `$InputFiles`
so any number of trailing bare args bind to it correctly regardless of
caller. Verify with a real 2+ file drag-drop after the fix, not just a
manual `-InputFiles a,b` call.

---

**Concise terminal progress for ffmpeg calls (log stays full)**

Supersedes/refines the 2026-07-11 entry below with a concrete design from
/think + /aristotle (2026-09-07). Root cause: every `& $ffmpegExe ...` call
is unredirected, and `Start-Transcript` captures whatever hits the console
- so the interactive terminal and the log file are served by the *same*
stream, which is why suppressing terminal noise without a real fix also
guts the log.

Design:
- Redirect ffmpeg's own stderr straight to the log file (`2>> $LogFile`,
  append - several passes/tools share one log).
- Use ffmpeg's own `-loglevel error -progress pipe:1` to get clean
  `key=value` progress lines (`out_time_ms=`, `speed=`) on a separate
  channel from the human-readable banner.
- One shared helper, `Invoke-FfmpegWithProgress`, renders a single
  self-overwriting terminal line (`\r`) like
  `Encoding: 42% (00:31/01:13, 2.1x)`.
- Only wrap calls that actually take long enough to matter: compress
  passes, landscape blur, cropfix re-encode, merge re-encode fallback,
  cropdetect scan. Stream-copy paths (trim fast-mode, merge stream-copy)
  keep a plain one-line status - a progress bar for a sub-second op is
  noise, not signal.
- On failure: keep the existing `ERROR: ... failed.` message, add
  `See log: $LogFile` - full diagnostic detail is only needed once
  something breaks, which is now exactly where it lives.

Deliberately NOT doing: a generic pluggable verbosity/config system,
colored/unicode progress bars, or instrumenting every call site
uniformly - that over-engineers a display tweak into its own subsystem.

---

**Multi-file batch flows - per-file actions, not just forced merge**

From /think + /aristotle (2026-09-07). Today, N>1 files silently forces
merge with zero prompting (`CLAUDE.md` documents this as the only
multi-file behavior). Real want: sometimes merge, sometimes independent
actions per file (e.g. compress file 1 AND trim file 2 from one drop),
all within a single terminal window.

Design - plan / execute / report, not parallel execution:
1. **Plan phase** (no ffmpeg calls yet): 1 file = today's behavior,
   unchanged. N files = ask ONE bootstrapping question, "Merge these
   into one file, or separate actions per file?" Merge -> today's
   `Invoke-Merge`, done. Separate -> loop file-by-file showing the
   existing menu (minus option 5/merge - merge doesn't make sense
   per-file) and queue `{file, action, params}` jobs without executing
   yet.
2. **Execute phase**: run queued jobs sequentially, each through
   `Invoke-FfmpegWithProgress` (see progress entry above).
3. **Report phase**: one consolidated results block instead of
   scattered per-job output.

Rejected: true parallel execution of 2+ ffmpeg processes at once. Two
CPU-bound `libx264 slow` encodes fight over the same cores (no GPU
encode path wired up) and interleaved output from two processes in one
window recreates the terminal-noise problem in a different shape.
Sequential-with-a-queue is what actually delivers "one terminal, any
number of videos" cleanly. Opportunistic parallelism for genuinely-fast
ops (stream-copy trim/merge) is a legitimate later enhancement, not part
of the first cut.

Required refactor: the single-file `Invoke-*` functions currently read
`$InputFile`/`$TargetMB`/`$ClipArgs` as module-level globals - they need
to take these as explicit parameters so the same function body serves
both the N=1 path (unchanged) and each queued job. **Acceptance test:
N=1 behavior must be provably identical to today's before calling this
done** - that's still the common case.

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
