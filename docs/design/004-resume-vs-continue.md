# 004: Resume vs continue strategy

Status: accepted

## Problem

Claude Code offers two ways to pick up a prior conversation:

- `claude --resume <session-uuid>` — restore that specific session by ID.
- `claude --continue` — restore the most recently active session (no ID needed).

These are not equivalent. Issue [#42338](https://github.com/anthropics/claude-code/issues/42338) reports that `--continue` invalidates the prompt cache via deferred_tools_delta reordering, forcing a full re-cache of 400–500k tokens on every resume. One affected user burned 1.43M cache_creation tokens across three resumes (~9× the useful output).

We want auto-resume to be **cheap** (don't burn next block's budget) AND **dummy-mode friendly** (work when the user hasn't captured a UUID).

## Constraints

- Must not require the user to know any UUID by default.
- Must avoid the `--continue` cache penalty when avoidable.
- Must degrade gracefully when `--resume` fails (session GC'd by Anthropic, JSONL deleted, etc.).
- Must let advanced users override with explicit UUIDs.

## Approach

A three-mode design configured via `CC_RESUME_MODE`:

### `auto` (default)

1. Check `$CC_SESSION_FILE` (written by [vibe-session-capture](003-session-capture.md)) and `$CC_SESSION_ID` (user-set env var).
2. If a UUID is available → `claude --resume <uuid>`. If that exits non-zero in <2 seconds with "session not found" on stderr → fall back to `--continue`.
3. If no UUID available → `claude --continue` directly. Log `[fallback] no session_id, using --continue (accepts cache rebuild)`.

### `session-id`

Always `claude --resume <uuid>`. If no UUID available, fail loudly. For users who explicitly want to detect when capture broke.

### `continue`

Always `claude --continue`. Simple dummy mode that accepts the cache cost. Useful for users who don't trust capture or just want predictable behavior.

### Final fallback (any mode)

If both resume paths fail (e.g., session truly garbage-collected and `--continue` also errors), launch a fresh `claude` and prepend `HANDOFF.md` content as the first user message so context isn't lost.

## Alternatives considered

- **Always `--continue`**: simple but burns cache for every user, every block.
- **Always `--resume`**: breaks when JSONL is missing or session capture failed; no friendly fallback.
- **Try to fix the cache invalidation upstream**: out of our scope, and even if Anthropic fixed it tomorrow, our wrapper is more robust handling both paths.
- **Spawn a fresh session every time + replay HANDOFF.md**: predictable but loses in-Claude session state (todo lists, /context state, etc.).

## API / file layout

Env vars in `bin/vibe-run`:

- `CC_RESUME_MODE` — `auto` (default) | `session-id` | `continue`.
- `CC_SESSION_ID` — explicit UUID override (skips reading `$CC_SESSION_FILE`).
- `CC_SESSION_FILE` — file path. Default `~/.vibe-run-session`.

Wrapper pseudo-code lives in the main flow section of `bin/vibe-run`. See plan file for the verbatim case statement.

## What NOT to implement

- **Do not** try to deduplicate sessions across multiple tmux panes / multiple wrapper invocations. One wrapper, one UUID, one resume.
- **Do not** add an "interactive picker" mode (asking the user which session to resume). The wrapper is automated; ambiguity should fail rather than prompt.
- **Do not** parse `claude --resume` output to detect success. Use exit code + exit time (< 2s with stderr "not found" pattern) only.
- **Do not** retry the same UUID more than once. If `--resume <X>` fails, switch to `--continue`; don't loop on the same UUID.

## Test plan

- Unit: stub `claude` to return success — assert wrapper completes one cycle.
- Unit: stub `claude --resume` to return "session not found" → assert wrapper falls back to `--continue`.
- Unit: `CC_RESUME_MODE=session-id` with no UUID → assert wrapper aborts with explicit error.
- Unit: `CC_RESUME_MODE=continue` → assert wrapper never calls `--resume`.
- Integration: real Claude session, force-delete the JSONL after capture, trigger a rate-limit cycle → assert fallback path runs and Claude still resumes (possibly with re-cache cost).
