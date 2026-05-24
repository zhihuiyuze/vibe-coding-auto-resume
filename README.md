# vibe-coding-auto-resume

Auto-resume Claude Code CLI after rate-limit resets so long agentic sessions, vibe-coding loops, and overnight tasks survive the 5-hour and weekly limits without manual restart.

[***English***](README.md) | [中文](README.zh.md) | [Français](README.fr.md) | [Русский](README.ru.md)

## The problem

If you use Claude Code (`claude`) for real work — long agentic tasks, multi-hour refactors, vibe-coding sessions over SSH — you eventually hit the wall:

- The 5-hour rate-limit window cuts off mid-task. You have to remember the reset time and manually restart `claude --continue`.
- Weekly limits do the same, on a longer clock.
- SSH disconnects kill the process entirely. Come back from lunch, the session is gone.
- There's no built-in way to see how much of the current block you've burned.
- Existing wrappers that watched for the rate-limit message broke as soon as Claude reworded the TUI.

`vibe-coding-auto-resume` is a small set of bash scripts that fixes all of the above without adding heavyweight dependencies.

## What this does

- **Runs `claude` inside tmux** so SSH disconnects, terminal closes, or laptop sleep don't kill your session.
- **Detects rate-limit hits with three layers**: JSONL parsing of `~/.claude/projects/*.jsonl` (L1), tmux pane regex on the verbatim TUI text (L2), and optional LLM classification (L3) for wording changes and edge cases.
- **Auto-resumes after reset**: sleeps until the extracted reset time + a small pad, then re-launches via `claude --resume <session-uuid>` (preferred, preserves cache) or `claude --continue` (fallback).
- **Captures the session UUID** automatically by watching the JSONL directory, so resume targets the exact session and avoids the `--continue` cache-invalidation bug.
- **`HANDOFF.md` continuity file** for cross-session context that should survive even a full restart.
- **L1+L2 work with zero external dependencies** (just `bash`, `jq`, `tmux`, `curl`). L3 is opt-in and off by default.

A background soft-cap monitor (v2) that warns Claude when you're approaching the limit so it can checkpoint progress is **planned, not yet implemented**.

## Install

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # if missing
source ~/.bashrc
```

The installer is idempotent: it symlinks `vibe-run` and `vibe-session-capture` into `~/.local/bin/`, appends a small tmux config snippet, and adds a `vibe work` shell function to `~/.bashrc`. It does not touch anything under `~/.claude/`.

## Usage

Typical workflow:

```bash
vibe work            # enter tmux session "claude" at your project cwd
vibe-run      # use this instead of `claude` — same flags, same behavior
# Ctrl+b d to detach. SSH can drop; the session keeps running.
# Later: vibe work again to reattach.
```

When `claude` exits because of a rate limit, `vibe-run` parses the reset time, sleeps until then (+60s pad), and resumes the same session UUID. When `claude` exits cleanly or with a real error, the wrapper exits with the same code — it does **not** blindly retry.

## L3 LLM opt-in

L1 (JSONL parsing) and L2 (pane regex) handle the common cases with zero external calls. For better handling of TUI wording changes and edge cases — and to extract reset times that L2's regex misses — you can opt in to L3 LLM classification.

Supported providers:

- **DeepSeek** (`DEEPSEEK_API_KEY`, model `deepseek-chat`) — cheapest
- **Anthropic Claude** (`ANTHROPIC_API_KEY`, model `claude-haiku-4-5`)
- **OpenAI** (`OPENAI_API_KEY`, model `gpt-4o-mini`)
- **Ollama** (local, `OLLAMA_HOST`) — interface implemented, currently `[untested]`, awaiting GPU validation

To enable:

```bash
export DEEPSEEK_API_KEY=sk-...   # add to ~/.bashrc so it persists
./install.sh                     # re-run; it will detect the key and prompt for opt-in
source ~/.bashrc
```

**Privacy note**: when L3 is enabled, the last ~30 lines of your tmux pane (conversation tail, file previews) are sent to the chosen provider for classification. Basic secret redaction (`sk-*`, `Bearer *`, `*_SECRET=*`, long base64) is on by default but is **not** a guarantee. Don't enable L3 on a pane that contains data you wouldn't paste into that provider's chat UI. Decline the opt-in to stay in L1+L2 mode even when a key is present.

## How detection works (TL;DR)

Three layers run in order. **L1** continuously knows how much of the current 5-hour block you've used by summing `message.usage.{input,output,cache_read}_tokens` across the current project's JSONL files; this drives the pre-flight refusal at the soft cap. **L2** runs `tmux capture-pane` on exit and greps the tail for verbatim rate-limit strings (`5-hour limit reached ∙ resets ...`, `weekly limit reached`, `Approaching 5-hour limit`) and extracts the reset time. **L3** (if opted in) sends that same tail to an LLM and gets back a structured `{status, reset_time, idle, modal_open}` JSON for cases L2 can't parse.

See [`docs/architecture.md`](docs/architecture.md) and [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md) for the full rationale.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CC_LLM_PROVIDER` | auto-detect, or `none` | Pick L3 provider (`deepseek` / `claude` / `openai` / `ollama` / `none`). `none` forces L1+L2 even if keys are set. |
| `CC_USAGE_THRESHOLD` | `0.75` | Soft cap fraction. Pre-flight refuses to start a new query above this. |
| `CC_RESUME_MODE` | `auto` | `auto` = `--resume <sid>` then fall back to `--continue`. `session-id` = strict UUID. `continue` = always `--continue`. |
| `CC_RESUME_MAX_CYCLES` | `1` | How many auto-resume cycles per wrapper invocation (`0` = unlimited). |
| `CC_COMPACTION_CHOICE` | `keep` | On the rare context-too-large compaction prompt after resume: `keep` (full context) or `compact` (let Claude summarize). |

Less-common knobs (`CC_SLEEP_PAD`, `CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_PEAK_FALLBACK`, `CC_SESSION_FILE`, `CC_LLM_MODEL`) are documented at the top of `bin/vibe-run`.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first — it's the single entry point for contributors. This project uses a **spec-first workflow**: every feature begins as a design doc in `docs/design/00X-<name>.md` (template in [`docs/design/README.md`](docs/design/README.md)) which is reviewed before any code is written. Bug fixes and small tweaks can skip straight to a PR.

New TUI patterns are especially welcome: if Claude Code ever emits a rate-limit or modal message we don't yet match, paste it verbatim into `tests/fixtures/<name>.txt` and open a PR.

## License

MIT.
