# 003: Session-id capture

Status: accepted

## Problem

To resume a Claude session cheaply (see [004](004-resume-vs-continue.md)), we need the session UUID. The CLI doesn't print it to stdout in interactive mode. We need a way to discover it without intercepting Claude's TTY.

## Constraints

- Cannot run `claude --output-format json` because that disables the interactive TUI; we want the TUI for the user.
- Must work even if multiple `claude` sessions are running concurrently — only capture the one started by this wrapper instance.
- Must not race the very first user message (the JSONL only exists after Claude has been given at least one turn).
- Must be quick — within a few seconds of session start.

## Approach

When the wrapper starts a Claude session, it spawns `vibe-session-capture` as a short-lived background process:

1. Snapshot the set of `*.jsonl` files currently in `~/.claude/projects/<encoded-cwd>/`.
2. Every 2 seconds, list the directory and diff against the snapshot.
3. When exactly one new file appears, take its basename (minus `.jsonl`) as the session UUID and write it to `$CC_SESSION_FILE` (default `~/.vibe-run-session`).
4. Exit successfully.
5. If 30 seconds pass with no new file, print a warning to stderr and exit non-zero. The wrapper continues without a session UUID and will fall back to `--continue` if a resume is later needed.

The encoded cwd matches Claude's directory naming (absolute path with `/` → `-`).

## Alternatives considered

- **Parse `claude --output-format json` first**: breaks the TUI. Non-starter for our interactive use case.
- **Inotify watch on the directory**: requires `inotifywait` (extra dep, often not installed on minimal Ubuntu). Polling is good enough for 2s granularity.
- **Re-read the JSONL files to verify they're ours**: more bash, more failure modes. Trust the directory + timestamp.
- **Capture the UUID from tmux pane output (it sometimes appears in `/status` or similar)**: too brittle, depends on the user running specific commands.

## API / file layout

`bin/vibe-session-capture` (standalone executable):

- Arguments: none (reads `$PWD` to compute the encoded cwd).
- Env: `CC_SESSION_FILE` (default `~/.vibe-run-session`), `CC_SESSION_TIMEOUT` (default `30`).
- Exit codes: `0` on success, `1` on timeout, `2` on multiple new files (ambiguous).

`bin/vibe-run` launches it as `vibe-session-capture &` immediately before `exec claude "$@"`.

## What NOT to implement

- **Do not** kill the vibe-session-capture background process if Claude exits early. It will time out and exit on its own.
- **Do not** retry beyond 30s. If no JSONL appears the user probably never sent a first message or cancelled out — let the wrapper handle the "no UUID captured" case downstream.
- **Do not** capture multiple UUIDs across multiple sessions. One file write, one exit. If the user starts a second claude in the same cwd, they need a second wrapper invocation.
- **Do not** clean up `$CC_SESSION_FILE` on exit — the wrapper needs it after `claude` itself exits. Old UUIDs are overwritten by the next capture; that's the cleanup story.

## Test plan

- Unit: create a temp dir, simulate a new file appearing after 1s, assert UUID is captured correctly.
- Edge: no new file appears within 30s → exit 1 with stderr warning.
- Edge: two new files appear simultaneously → exit 2 (caller can decide how to handle ambiguity).
- Integration: run alongside a real `claude` invocation, assert the captured UUID matches `claude /status`'s reported session.
