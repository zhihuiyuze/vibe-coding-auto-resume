# Manual E2E test project

This subdir is intentionally small. Used by README scenario walkthrough:
- `vibe work` from here should create tmux session "vibe-<hash>" with cwd = this dir.
- `vibe run --resume <uuid>` flag parsing should extract uuid without launching claude when claude is stubbed.

Not under .gitignore; checked in as a stable test target.
