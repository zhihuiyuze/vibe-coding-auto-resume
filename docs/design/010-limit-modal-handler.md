# 010: Interactive limit-hit modal handler

Status: accepted

## Problem

Claude Code (observed in a recent build past v2.1.150) replaced the
single-line "5-hour limit reached ∙ resets 12pm" print + immediate exit
with an interactive modal:

    What do you want to do?

     ❯ 1. Stop and wait for limit to reset
       2. Switch to usage credits
       3. Upgrade your plan

       Enter to confirm · Esc to cancel

This breaks vibe-run's "wait for `claude` to exit, then triage" contract:
`claude` blocks indefinitely waiting for a keypress. SSH disconnect doesn't
help — the modal sits in the tmux pane until the user resolves it manually.
A user reported exactly this: SSH disconnected, came back hours later, the
modal was still there, no auto-resume happened.

## Constraints

- Must not auto-pick options that cost money (option 2 = usage credits)
  or change the user's plan (option 3 = upgrade).
- Must not send keys when `claude` is at the chat prompt — risk of
  injecting "1" or Enter as a chat message.
- L3 LLM is opt-in; the fix must work in degraded (L1+L2 only) mode too.
- The modal text does NOT contain a reset clock-time, so the existing
  `extract_reset_time` regex is insufficient.

## Approach

A background watcher is spawned alongside each `claude` invocation:

1. Poll `tmux capture-pane` every `CC_MODAL_POLL_INTERVAL` (default 5s).
2. If `pane_grep limit_modal` matches the distinctive line
   ("Stop and wait for limit to reset"):
   a. `tmux send-keys -t <target> Enter` — the cursor defaults to "❯ 1."
      per Anthropic's UI, so Enter alone selects "Stop and wait".
   b. Touch a state file at
      `$VIBE_STATE_DIR/$VIBE_SESSION/modal-detected-at` containing the
      ISO timestamp of detection.
   c. Sleep `CC_MODAL_QUIESCE` (default 10s) before resuming the poll
      loop — avoids re-triggering on the same modal.
3. Watcher exits when `claude` exits.

After `claude` exits, vibe-run's post-exit triage gains a new branch:
if the state file exists and was touched recently, treat as a limit
hit. Reset time is sourced from `jsonl_stats.block_end_iso` — the 5-hour
block end is the canonical moment the user can resume. The state file is
then deleted so it can't trigger a stale resume next cycle.

If the user picked "Stop and wait" and Anthropic's built-in logic causes
`claude` to internally sleep + resume without exiting, the watcher just
keeps idling and `wait $claude_pid` blocks — no harm, no fallback path
needed. The state-file branch only fires if `claude` actually exits.

## Why send only Enter (not "1" + Enter)

- The modal's own indicator (`❯ 1.`) shows the cursor is already on
  option 1 — Enter selects it.
- Sending the literal character "1" is dangerous if the modal somehow
  dismissed between our `pane_grep` and our `send-keys` — the "1" would
  be injected as a chat message.
- Plain Enter at the chat prompt submits an empty message, which Claude
  ignores. Net cost of a stale-fire false-positive: zero.

## Alternatives considered

- **"1" + Enter explicitly.** Rejected — race window above.
- **Esc + a `/quit` slash command.** Rejected — relies on undocumented
  slash command shape; brittle to UI evolution.
- **Let L3 LLM decide which option to pick.** Rejected — the safe option
  is unambiguous; LLM latency adds risk of the user manually picking
  first; LLM call costs more than a string match.
- **No state file; rely purely on existing patterns matching post-exit.**
  Rejected — the modal text doesn't contain "5-hour limit reached" or
  "resets <time>", so the existing `limit` pattern doesn't match, and we
  cannot extract a reset time. The state file carries the signal across
  the exit boundary.

## API / file layout

New / changed:

- `config/grep-patterns.txt`
  - New group `limit_modal:Stop and wait for limit to reset`.
- `lib/tmux-pane.sh`
  - New function `watch_limit_modal <claude_pid>`.
- `bin/vibe-run`
  - Refactor the initial `claude` invocation to the background-pid +
    watcher pattern already used by `run_resume_cycle`.
  - Spawn `watch_limit_modal` in `run_resume_cycle` too.
  - Post-exit: check for `$VIBE_STATE_DIR/$VIBE_SESSION/modal-detected-at`;
    if present, set `hit=1` and derive `reset_iso` from
    `jsonl_stats.block_end_iso`. Delete the file before sleeping.
  - Startup: delete any leftover state file from a prior run.
- `tests/fixtures/limit-modal-3option-1.txt`
  - Verbatim transcription of the modal.
- `tests/smoke.sh`
  - L2 fixture-classification case: `limit_modal-3option-1.txt` matches
    group `limit_modal`, must NOT match `limit`, `weekly_limit`,
    `warning`, `api_error`.

New env vars:
- `CC_MODAL_POLL_INTERVAL` (default 5)
- `CC_MODAL_QUIESCE` (default 10)
- `CC_MODAL_STATE_FILE` (default `$VIBE_STATE_DIR/$VIBE_SESSION/modal-detected-at`)
- `CC_MODAL_STATE_TTL` (default 1800; seconds; state file older than this
  is ignored as stale)

## What NOT to implement

- Auto-picking option 2 or 3. **Ever.** Option 2 costs real money;
  option 3 changes the user's billing plan. Strictly out of scope.
- Sending keys without first matching `limit_modal` in the current pane.
  No "blind retry" loops.
- Cross-vibe-run-invocation modal state. State file is per-session and
  cleaned up at vibe-run startup AND post-handling. Modal detected in a
  previous shell invocation is not relevant to the current one.
- Custom UI navigation (arrow keys, multiple keystrokes). Out of scope —
  Enter on the default option is enough for the only safe choice.
- Updating the modal pattern for languages other than English (Anthropic
  has not localized the modal so far). Will revisit if/when observed.

## Test plan

- **Unit (L2)**: `pane_grep limit_modal` matches the new fixture; does
  NOT match any other existing fixture (no false positives).
- **Integration (smoke.sh)**: fixture added to the `CASES` table with
  `should_match=limit_modal`, all other groups in `should_not_match`.
- **Manual E2E** (requires a real rate-limit hit):
  1. Run `vibe run` inside tmux, burn through a 5-hour block.
  2. When the modal appears, observe:
     - `[vibe-run] Limit modal detected; sending Enter (Stop and wait).` in stderr
     - State file exists at `$VIBE_STATE_DIR/$VIBE_SESSION/modal-detected-at`
  3. If `claude` exits after the keystroke:
     - vibe-run reads the state file, queries L1 for `block_end_iso`,
       sleeps until then, resumes.
  4. If `claude` self-resumes without exiting:
     - The watcher idles; user sees Anthropic's own wait + resume flow.
- **Regression**: existing fixtures (`5h-limit-1.txt`, `weekly-opus-1.txt`,
  `approaching-1.txt`, `api-error-tz.txt`, `normal-exit.txt`,
  `real-error.txt`) must still classify identically.
