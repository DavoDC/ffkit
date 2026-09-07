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
