# dependencies/ffmpeg/

This folder holds the FFmpeg binary. It is gitignored - populated automatically on first run.

**Do not commit binaries here.**

When you run any ffkit tool for the first time, FFmpeg is downloaded here automatically.
To use a system FFmpeg instead, ensure `ffmpeg` is on your PATH - the tools check PATH first.

## Manual install

Download from https://www.gyan.dev/ffmpeg/builds/ and extract `ffmpeg.exe` and `ffprobe.exe` into this folder.
