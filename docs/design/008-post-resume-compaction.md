# 008: Post-resume compaction handling

Status: accepted

## Problem

When the wrapper auto-resumes a session via `claude --resume <uuid>` or `claude --continue`, Claude Code sometimes shows a **compaction prompt** asking the user whether to compact the conversation history before continuing (referenced in issues #46751, #42146). If unanswered, the wrapper sits at this prompt forever — defeating the whole "auto" in auto-resume.

We need to detect this prompt and answer it without user intervention.

## Constraints

- **The verbatim prompt text and keybinding are not publicly documented** as of Claude Code v2.1.150. Public issue references mention the behavior but no one transcribed the exact UI.
- Detection must not false-positive on normal output (the words "compact" or "summarize" can appear in user prompts or Claude's own responses).
- Wrong answer is destructive — choosing "compact" when user wanted full context loses detail; choosing "keep" when context truly was too large can cause issues downstream.
- Default behavior should preserve maximum context (best for tight-loop continuation).

## Approach

### Phase 1 (v1, ships now): detect-and-warn

`lib/tmux-pane.sh::handle_post_resume <pid>`:

1. Wait 2 seconds for the resumed session to settle.
2. For the next 15 seconds (1-second polling), `capture_tail` + `pane_grep compaction`.
3. If a match → print `[post-resume] Compaction prompt detected. Verbatim text unknown for this Claude Code version. Please answer manually in the tmux window. Save the prompt text to tests/fixtures/compaction-prompt-1.txt to help us auto-handle it next time.` and exit the handler.
4. If no match in 15 seconds → silent exit (the common case: no compaction prompt appeared).

### Phase 2 (post-v1, after fixtures collected): detect-and-answer

Once we have at least one verbatim sample in `tests/fixtures/compaction-prompt-*.txt`:

1. Add patterns to `config/grep-patterns.txt` for both the prompt and the option keys.
2. Extend `handle_post_resume` to inspect `CC_COMPACTION_CHOICE`:
   - `keep` (default) → send the keystroke for "no/keep/preserve".
   - `compact` → send the keystroke for "yes/compact/summarize".
3. Verify after sending — if the prompt is still on screen 3 seconds later, fall back to print-warning mode (don't get stuck in a key-sending loop).

### Env vars

- `CC_COMPACTION_CHOICE` — `keep` (default) | `compact`. Used by Phase 2 only; ignored in Phase 1.

## Alternatives considered

- **Auto-pick "compact" always**: aggressive, would summarize away detail users may need.
- **Auto-pick "keep" always**: preserves context but if context truly was too large, the session might OOM downstream. Mitigated by user's awareness — they can switch to `compact` mode.
- **Skip handling entirely, let the user deal**: defeats auto-resume goal. Even a warning is more useful than silence.
- **Use L3 LLM to detect and respond**: overkill — the pattern is fixed text. L3 is for variable-wording cases.

## API / file layout

`lib/tmux-pane.sh`:

```bash
handle_post_resume()        # arg: pid of claude (informational only, not used to kill)
                            # Phase 1: detect + warn
                            # Phase 2 (later): detect + answer per CC_COMPACTION_CHOICE
```

`bin/vibe-run` calls `handle_post_resume $resume_pid &` after launching `claude --resume`/`--continue`.

`config/grep-patterns.txt` adds (Phase 1, broad/loose):

```
compaction:compact|summari[sz]e|context.{0,20}large|conversation.{0,20}long
```

Phase 2 updates this once fixtures are in.

## What NOT to implement

- **Do not** auto-answer in Phase 1. We don't know the verbatim text; guessing the keybinding has too many failure modes.
- **Do not** kill claude when the compaction prompt is up. Let the user answer manually — they'll see the warning we printed.
- **Do not** intercept other modals (permission prompts, etc.) here. Those are a separate concern; this handler is scoped to compaction only.
- **Do not** assume the prompt always appears after `--resume`. It's conditional on session size; most resumes won't trigger it.

## Test plan

- Unit: fixture `compaction-prompt-*.txt` (placeholder content) → `pane_grep compaction` returns hit. Real verbatim sample TBD.
- Unit: pane with normal Claude output containing the word "compact" in code → false-positive expected; document accepted false-positive rate.
- Integration (Phase 1): in tmux, run `claude --continue` on a real session, observe `handle_post_resume` either prints a warning (if compaction shown) or exits silently (if not).
- Integration (Phase 2, when fixtures land): assert keystroke is sent and the prompt disappears within 3 seconds.
