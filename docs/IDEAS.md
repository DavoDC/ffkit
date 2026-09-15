# Ideas & Future Work

Single source of truth for all pending work in this repo. Settled decisions and completed features -> `docs/HISTORY.md`.

---

## Current Focus

Active development - adding more tools to `scripts/`.

---

## Pending - Main Work

---

**Raphael machine - pull repos and delete local FFmpeg copies**

Pull latest on known consumer repos (sibling-check already in main), then delete the local `dependencies/ffmpeg/` copy from each. **Also needed:** update each consumer's code to call into ffkit instead of using local copies.

---

**Auto-update detection for FFmpeg**

FFmpeg binary bundled here can become stale. Consumer repos using ffkit should always run a recent version. Design needed: (1) When to check for updates? (e.g., on each call, once per day, if >7 days old). (2) When to auto-update? (e.g., on major version bump, weekly schedule, user opt-in). (3) Where to store last-update timestamp? ffkit should detect stale binaries and update transparently so all consumers auto-benefit. **Design TBD** - coordinate with ytkit for consistency.

---

**Ensure all consumer repos use ffkit instead of local ffmpeg**

Audit all consumer repos: multiple have local `dependencies/ffmpeg/` copies. Remove these and call into ffkit instead so all consumers use the single authoritative source. Prevents version skew. Depends on auto-update detection above. Use sibling-check pattern already in main to identify consumers and automate the removal/migration.

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
