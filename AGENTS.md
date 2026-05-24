# vibe-coding-auto-resume

Auto-resume Claude Code CLI after rate-limit resets. Tmux + JSONL parsing + optional LLM detection. Zero-dep core, opt-in DeepSeek/Claude/OpenAI/Ollama.

## What this is

A wrapper around `claude` (the Claude Code CLI) that survives the 5-hour rate-limit window and weekly limits without manual intervention.

- Runs `claude` inside tmux, so SSH disconnects don't kill the session.
- Detects rate-limit hits using three layers (deterministic-first, LLM-optional).
- Sleeps until the rate-limit reset time, then resumes the same Claude session.
- Maintains a `HANDOFF.md` continuity file so cross-session context isn't lost.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and data flow.

TL;DR:

```
shell → vibe work (tmux) → vibe-run (wrapper) → claude
                              │
                              ├── pre-flight: L1 jsonl-stats + L2 pane-grep [+ L3 LLM if opt-in]
                              ├── on exit:    L2 pane-grep → L3 LLM (if opt-in) → classify
                              └── on limit:   sleep until reset → claude --resume <sid> | --continue
```

## Three-layer detection (TL;DR)

| Layer | Source | Default | Cost |
|---|---|---|---|
| L1 | `lib/jsonl-stats.sh` — reads `~/.claude/projects/<encoded-cwd>/*.jsonl`, sums `message.usage` tokens, derives block start/end and historical peak | on | 0 |
| L2 | `lib/pane-grep.sh` — `tmux capture-pane` last N lines, regex-matches verbatim Claude TUI strings (rate-limit, weekly limit, approaching warning), extracts reset time | on | 0 |
| L3 | `lib/llm-classify.sh` — sends the pane tail to DeepSeek / Claude Haiku 4.5 / OpenAI gpt-4o-mini / Ollama, gets back structured JSON (`status`, `reset_time`, `idle`, `modal_open`) | **opt-in** at install time | small API call per event |

Full rationale in [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md).

## Repo layout

```
.
├── AGENTS.md           ← you are here
├── CLAUDE.md           ← symlink to AGENTS.md (so the Claude Code CLI picks it up)
├── README.md           ← user-facing intro (English)
├── README.zh.md        ← 中文
├── README.fr.md        ← Français
├── README.ru.md        ← Русский
├── bin/                ← executable entry points (vibe-run, vibe work, vibe-session-capture)
├── lib/                ← sourced bash modules (jsonl-stats, pane-grep, llm-classify, tmux-pane)
├── config/             ← editable patterns + prompts + tmux snippet + templates
├── docs/
│   ├── architecture.md
│   ├── design/         ← one design doc per feature (spec-first workflow)
│   └── plans/          ← phased implementation plans
├── install.sh          ← idempotent installer (no sudo; prompts for L3 opt-in)
├── uninstall.sh
└── tests/
    ├── smoke.sh        ← unit + integration tests
    └── fixtures/       ← verbatim Claude TUI samples for regex/LLM validation
```

## How to propose a change

This project follows **spec-first development**. For anything bigger than a single-file tweak:

1. Copy the template from [`docs/design/README.md`](docs/design/README.md) into `docs/design/00X-<kebab-name>.md`.
2. Fill in the fixed sections: Status, Problem, Constraints, Approach, Alternatives considered, API / file layout, **What NOT to implement**, Test plan.
3. Open a PR with just the design doc. Get feedback on direction before implementing.
4. Implement against the accepted doc (yourself or hand it to an agent).
5. Reference the doc in your commit: `feat(L3): add deepseek provider (docs/design/005)`.

The "What NOT to implement" section is load-bearing: it gives both human and agent implementers explicit scope boundaries.

## Local development

Clone, then:

```bash
# Run tests (no Claude needed; uses fixtures + mocked LLM):
bash tests/smoke.sh

# Add a new TUI pattern (e.g. a new rate-limit wording from a future Claude Code release):
#   1. Save the verbatim text to tests/fixtures/<your-case>.txt
#   2. Add or extend a line in config/grep-patterns.txt
#   3. Run smoke.sh — your fixture should match

# Swap LLM providers:
export CC_LLM_PROVIDER=openai   # or claude, deepseek, ollama
# (key env var picked up automatically based on provider)
```

### Configuration locations

| What | Where |
|---|---|
| LLM keys / tunables (global) | `${XDG_CONFIG_HOME:-~/.config}/vibe/env` (chmod 600) |
| Per-session state | `${XDG_STATE_HOME:-~/.local/state}/vibe/<session-name>/` |
| Workspace continuity (opt-in) | `<your-project>/HANDOFF.md`, `<your-project>/CLAUDE.md` markers — only when you run `vibe setup-workspace` from inside that project |

The bashrc marker block installed by `install.sh` wraps the source of
`~/.config/vibe/env` with `set -a` / `set +a`, so both `export KEY=value`
and bare `KEY=value` lines get exported to subprocesses.

## Conventions

- **Source language**: English. Code, comments, commits, AGENTS.md, docs, CLI output.
- **Translations**: README only, four languages (`README.md`, `README.zh.md`, `README.fr.md`, `README.ru.md`). Top-of-file cross-link block.
- **No third-party attribution markers** in artifacts. Keep the surface clean.
- **Bash style**: `set -euo pipefail` at top of every script. Prefer `[[ ]]` over `[ ]`. Quote variables. `local` in functions.
- **Commits**: `<type>(<scope>): <summary> (docs/design/0XX)`. Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

## Testing

- **Fixtures** in `tests/fixtures/` are verbatim text Claude has emitted in real sessions (transcribed from GitHub issues or captured by users). They drive regex/LLM unit tests.
- **`tests/smoke.sh`** runs L1 (against a sample JSONL), L2 (against each fixture), L3 (against a mocked HTTP server), and end-to-end wrapper logic.
- **Real-API smoke test**: when an API key is set, `smoke.sh` will optionally make one round-trip per provider against the actual API. Skipped when keys are absent.
- **New fixtures welcome**: if you see a Claude TUI message we don't yet match, paste the verbatim text into `tests/fixtures/<name>.txt` and open a PR.
