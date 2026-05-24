# 007: Soft-cap monitor (v2)

Status: draft

## Problem

The pre-flight check (see [006](006-degraded-mode.md)) only fires at wrapper startup. Once `claude` is running, it can burn through the entire block uninterrupted, leaving the user with 0% budget for ad-hoc questions in the remaining window.

A common scenario: user starts a long agentic task, leaves the terminal, returns five hours later to find Claude consumed the whole block and the next reset is hours away.

We want a soft cap that, mid-session, asks Claude to wrap up gracefully before the hard limit hits.

## Constraints

- Must not interrupt Claude mid-tool-call (corrupts git/file state).
- Must not insert keystrokes into Claude's input draft buffer (would lose user-typed text).
- Must not answer permission/modal prompts on the user's behalf.
- Must require L3 LLM to be enabled — only an LLM can reliably distinguish "Claude is idle waiting for input" from "Claude is mid-generation" from "Claude is showing a modal" via tmux pane state.
- Privacy: this daemon polls the pane periodically, so it sends pane content to L3 more often than wrapper-only mode.

## Approach

A background daemon (`bin/cc-cap-monitor`) launched by `vibe work` (or manually) alongside the wrapper:

### Loop

Every `CC_CAP_POLL_INTERVAL` (default 120 seconds):

1. Run `jsonl_stats` to get `block_pct`.
2. If `block_pct < CC_USAGE_THRESHOLD` (default 0.75): noop, sleep, repeat.
3. If `block_pct >= CC_USAGE_THRESHOLD` AND we haven't yet fired this block:
   a. Run `pane_grep warning` — confirms Anthropic's UI is also seeing it.
   b. If L3 disabled: print `[cap-monitor] Threshold crossed but L3 disabled; cannot safely auto-inject. Update HANDOFF.md manually.` and skip.
   c. If L3 enabled: call `llm_classify` on the current pane.
      - If `idle == true && modal_open == false` → safe to inject.
      - Else → wait 30s and retry idle check (up to 5 times).
4. On successful idle check, `tmux send-keys -t claude "Please save current progress to HANDOFF.md (Current task, Completed, Next steps, Blockers, Context). Then stop and exit when done." Enter`.
5. Mark this block as fired (flag file `/tmp/cc-cap-<session-uuid>.flag`).
6. Optional verification: 90s after injection, check `~/dev/<project>/HANDOFF.md` mtime. If unchanged, re-inject once with stronger wording.

### Concurrency

`cc-cap-monitor` runs in a separate tmux pane (or detached). Its log goes to `~/.cc-cap-monitor.log`. Stopped by `Ctrl+C` or by `vibe work` exiting.

## Alternatives considered

- **Send SIGTERM/SIGINT to claude instead of injecting**: corrupts mid-tool state.
- **Use a Claude Code hook (PreCompact/Stop/SessionStart)**: hooks fire on Claude events, not on external token thresholds; wrong direction.
- **Don't auto-inject — just print a desktop notification**: SSH user won't see it; tmux + bell isn't reliable across SSH.
- **Hardcode the threshold lower (e.g. 60%)**: removes the user's control over reserve size. 75% with env var override is the right tradeoff.

## API / file layout

`bin/cc-cap-monitor` (standalone executable):

- Env: `CC_USAGE_THRESHOLD`, `CC_CAP_POLL_INTERVAL`, `CC_CAP_FLAG_DIR` (default `/tmp`), `CC_TMUX_SESSION` (default `claude`).
- Reads HANDOFF.md path from `~/dev/<project>` — assumes the tmux session's `start-directory` is the project root.

`lib/handoff.sh`:

```bash
read_handoff()                    # cat ~/dev/<project>/HANDOFF.md
verify_handoff_written(since_ts)  # check mtime > since_ts
```

## What NOT to implement

- **Do not** inject if L3 is disabled. The safety net we have for "is the pane idle?" is L3; without it the failure mode is corrupting Claude's draft or answering a modal.
- **Do not** kill `claude` if HANDOFF.md isn't written after injection. The user may have manually engaged; killing destroys state.
- **Do not** fire more than once per block. If the user wants to silence the cap-monitor for a session, they can `pkill cc-cap-monitor`.
- **Do not** write HANDOFF.md ourselves. Only Claude can do that meaningfully; cap-monitor only requests it.
- **Do not** ship this in v1. The send-keys safety surface is large enough that we want v1 (no mid-run injection) shipped and proven first.

## Test plan

- Unit: stub `jsonl_stats` returning various `block_pct`, assert injection happens only above threshold and only once.
- Unit: stub `llm_classify` returning `idle=false`, assert injection is delayed.
- Unit: stub `llm_classify` returning `modal_open=true`, assert injection is skipped.
- Integration: in a real tmux session, set `CC_USAGE_THRESHOLD=0.0001` (always over), assert injection happens within one poll interval and HANDOFF.md gets written by Claude.
- E2E: real long task, real block — manual verification.
