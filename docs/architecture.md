# Architecture

## High-level flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Shell (SSH session)                                                    │
│    │                                                                    │
│    └─ vibe work (alias)                                                   │
│         │                                                               │
│         └─ tmux session "claude" (persistent across SSH disconnects)    │
│              │                                                          │
│              └─ vibe-run (wrapper)                                 │
│                   │                                                     │
│                   ├─ pre-flight check                                   │
│                   │    ├─ L1: lib/jsonl-stats.sh  (read JSONL, % used)  │
│                   │    ├─ L2: lib/pane-grep.sh    (look for warnings)   │
│                   │    └─ L3: lib/llm-classify.sh (if opt-in, confirm)  │
│                   │       → refuse if usage above CC_USAGE_THRESHOLD    │
│                   │                                                     │
│                   ├─ bin/vibe-session-capture &  (async: watch JSONL dir) │
│                   │    └─ writes new session UUID to ~/.vibe-run-session
│                   │                                                     │
│                   ├─ exec claude "$@"                                   │
│                   │                                                     │
│                   └─ on exit:                                           │
│                        ├─ L2 pane-grep for limit keywords               │
│                        │    └─ if none → exit with original code        │
│                        ├─ L3 LLM classify (if opt-in)                   │
│                        │    └─ extract precise reset_time               │
│                        ├─ sleep until reset_time + CC_SLEEP_PAD         │
│                        ├─ claude --resume <sid>  (or --continue)        │
│                        │    └─ handle_post_resume & (compaction prompt) │
│                        └─ loop until CC_RESUME_MAX_CYCLES reached       │
└─────────────────────────────────────────────────────────────────────────┘
```

## Module responsibilities

### `bin/`

- **`vibe-run`** — main wrapper. Orchestrates pre-flight, exec, exit classification, sleep, resume. Reads all env vars (`CC_*`). Should not contain any detection logic itself — delegates to `lib/`.
- **`vibe work`** — defined as a bash function in `~/.bashrc`. `cd`s into the project, creates or attaches the `claude` tmux session.
- **`vibe-session-capture`** — short-lived background process. On launch snapshots `~/.claude/projects/<encoded-cwd>/*.jsonl`, polls every 2s for new files, writes the new UUID to `$CC_SESSION_FILE`, exits. Timeout 30s.
- **`cc-cap-monitor`** *(v2)* — long-lived daemon. Periodically runs L1, when threshold crossed runs L2/L3 to verify, injects "save HANDOFF.md and wrap up" prompt via `tmux send-keys` (only if L3 confirms idle and no modal).

### `lib/` (sourced bash modules; no executables)

- **`jsonl-stats.sh`** — L1. Functions: `encoded_cwd`, `current_session_jsonl`, `block_tokens`, `block_start_iso`, `block_end_iso`, `historical_peak`, `jsonl_stats` (composite JSON output). Pure jq parsing of Anthropic's local data. Defensive about missing fields (`// empty`).
- **`pane-grep.sh`** — L2. Functions: `capture_tail`, `pane_grep <group>`, `extract_reset_time`. Patterns loaded from `config/grep-patterns.txt`.
- **`llm-classify.sh`** — L3. Functions: `detect_provider`, `redact`, `llm_classify <text>`. Multi-provider dispatch (DeepSeek/Claude/OpenAI/Ollama). Output is normalized JSON regardless of provider. Network errors map to `status=error` so the wrapper doesn't mistakenly auto-resume.
- **`tmux-pane.sh`** — helpers. `detect_idle` (capture-pane + regex), `handle_post_resume <pid>` (background polls for compaction prompt, prints warning or auto-answers based on `CC_COMPACTION_CHOICE`).
- **`handoff.sh`** *(v2)* — `read_handoff`, `verify_handoff_written <since-ts>` (for v2 cap-monitor flow).

### `config/`

- **`tmux.conf.snippet`** — appended to `~/.tmux.conf` by installer. Three Anthropic-required lines plus quality-of-life settings (history-limit, true-color).
- **`grep-patterns.txt`** — one `group:regex` per line. Editable; the installer doesn't touch it after first install so user customizations persist.
- **`classify-prompt.txt`** — LLM system prompt with response schema.
- **`handoff-template.md`** — seed for `HANDOFF.md` in user's working repo.
- **`claude-md-rule.md`** — snippet appended to user's `~/dev/<project>/CLAUDE.md` describing the auto-resume + HANDOFF.md convention.

### `install.sh`

- Idempotent. Detects deps, prompts for L3 opt-in (only if an API key is present in env), creates symlinks in `~/.local/bin/`, appends to `~/.tmux.conf` and `~/.bashrc` inside marker blocks, creates HANDOFF.md and CLAUDE.md in the user's project. Never invokes sudo — prints required sudo commands for the user to run.

## Data flow

### Where state lives

| State | Location | Owner |
|---|---|---|
| Session UUID (current) | `~/.vibe-run-session` (one line) | `vibe-session-capture` writes; `vibe-run` reads |
| Per-block token counts | `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` | Claude Code itself; we only read |
| Current tmux session name | tmux server in-memory; default `claude` | `vibe work` creates; `vibe-run` requires `$TMUX` set |
| L3 opt-in flag | `~/.bashrc` env var `CC_LLM_PROVIDER` | installer writes; wrapper reads |
| User project context | `~/dev/<project>/HANDOFF.md` | Claude (or v2 cap-monitor injection) writes; new sessions read |

### What gets sent to LLM (L3 only)

When L3 is opt-in enabled, the wrapper sends to the chosen API:

- **System prompt**: contents of `config/classify-prompt.txt` (~500 tokens, fixed)
- **User payload**: redacted last 30 lines of `tmux capture-pane -p`. Redaction (default on) masks `sk-*`, `Bearer *`, `*_SECRET=*`, and long base64 runs.

The user is informed of this at install time and must explicitly `y/N`-opt-in. The opt-in is per-machine, persisted in `~/.bashrc`.

### What never leaves the machine

- JSONL files (L1 reads locally)
- The user's source code (unless it happens to be visible in the tmux pane tail at the moment L3 is invoked — see redaction notes above)
- Session UUIDs
- HANDOFF.md content (lives in user's project repo; never sent anywhere by this tool)
