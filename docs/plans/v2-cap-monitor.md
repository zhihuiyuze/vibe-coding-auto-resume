# v2: Soft-cap monitor

## Goal

Mid-run injection of a "save HANDOFF.md and stop" prompt when token usage crosses a soft threshold, preserving interactive budget for the rest of the 5-hour block.

## Designs implemented

- [007](../design/007-soft-cap-monitor.md) — soft-cap daemon
- HANDOFF.md verification flow (extension of [007](../design/007-soft-cap-monitor.md))

## Status

Not started. Blocked on v1 being proven in real use first — the send-keys injection surface is risky enough that we want L1/L2/L3 plumbing battle-tested before layering this on.

Open issues to resolve before starting:
- Verbatim Claude TUI text for the "are you sure you want to interrupt me" idle state — needs fixtures.
- Whether `tmux send-keys ... Enter` is reliable when Claude is in `/edit`-style multiline mode.
- Whether Phase 2 of [008](../design/008-post-resume-compaction.md) lands first so we have a known-good send-keys flow to reuse.
