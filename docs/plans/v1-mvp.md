# v1: MVP

## Goal

First shippable wrapper that survives `claude` rate-limit hits without user babysitting — wraps `claude` inside tmux, classifies exit reason via L1+L2 (+ optional L3), sleeps until reset, resumes the same session, and warns on post-resume compaction prompts.

## Designs implemented

- [001](../design/001-three-layer-detection.md) — three-layer detection (L1+L2 default, L3 opt-in)
- [002](../design/002-jsonl-parsing.md) — JSONL parsing for L1
- [003](../design/003-session-capture.md) — session-id capture via JSONL watching
- [004](../design/004-resume-vs-continue.md) — `--resume <uuid>` preferred, `--continue` fallback
- [005](../design/005-llm-provider-abstraction.md) — DeepSeek/Claude/OpenAI/Ollama branches
- [006](../design/006-degraded-mode.md) — explicit degraded-mode contract
- [008](../design/008-post-resume-compaction.md) — Phase 1 detect-and-warn

## Phases

### Phase A: Spec layer
- Write `AGENTS.md` (entrypoint) ✓
- Write `docs/architecture.md` ✓
- Write `docs/design/00{1..6,8}.md` ✓
- Write `docs/design/README.md` ✓
- Write this plan ✓

### Phase B: Config layer
- `config/tmux.conf.snippet`
- `config/grep-patterns.txt` (verbatim Claude TUI strings, U+2219 separator)
- `config/classify-prompt.txt`
- `config/handoff-template.md`
- `config/claude-md-rule.md`

### Phase C: Lib layer
- `lib/jsonl-stats.sh` (L1)
- `lib/pane-grep.sh` (L2)
- `lib/llm-classify.sh` (L3 — 4 provider branches incl. Ollama [untested])
- `lib/tmux-pane.sh` (capture_tail, detect_idle, handle_post_resume Phase 1)

### Phase D: Bin layer
- `bin/vibe-session-capture`
- `bin/vibe-run` (main wrapper)
- `bin/vibe work` (defined as shell function, installer appends to `~/.bashrc`)

### Phase E: Installer
- `install.sh` (deps check, L3 opt-in, symlinks, idempotent appends)
- `uninstall.sh`

### Phase F: Tests
- `tests/fixtures/5h-limit-1.txt` — verbatim from GH issues
- `tests/fixtures/weekly-opus-1.txt`
- `tests/fixtures/approaching-1.txt`
- `tests/fixtures/api-error-tz.txt`
- `tests/fixtures/compaction-prompt-1.txt.placeholder` (waiting for real sample)
- `tests/smoke.sh`

### Phase G: User docs
- `README.md` (English)
- `README.zh.md`
- `README.fr.md`
- `README.ru.md`

### Phase H: Verification
- Run `tests/smoke.sh`
- Run `install.sh` (dry-run-friendly path)
- Manual smoke: `vibe work` → `vibe-run --version`
- Self-audit: launch `vibe-run` and have Claude itself read the design docs + run smoke.sh + report findings

## Verification

All of these must pass before v1 is declared "shipped":

1. `bash tests/smoke.sh` returns 0.
2. `bash install.sh` (with no `*_API_KEY` set) → prompts L1+L2 mode, creates symlinks, appends snippets idempotently.
3. `which vibe-run vibe-session-capture` both resolve under `~/.local/bin/`.
4. `readlink CLAUDE.md` resolves to `AGENTS.md`.
5. `tmux show -g | grep allow-passthrough` shows `on` after sourcing tmux config.
6. `vibe-run --version` (run inside a tmux session) returns the same version as bare `claude --version`.
7. Sampling each fixture through `pane_grep`, the right group matches with `extract_reset_time` parsing the expected ISO timestamp.
8. With a DeepSeek/Claude/OpenAI key set, `llm_classify` against `5h-limit-1.txt` returns `status=limit_hit` and a non-null `reset_time`.
9. With no API key and a stubbed pane returning a limit message with **no** parseable reset time, `vibe-run` exits with the `[degraded mode] ... Not resuming.` message.
10. `handle_post_resume` exits silently when no compaction prompt is shown.

## Done definition

- All Phase A–G files exist and `wc -l` totals roughly match the design estimates (don't gold-plate).
- All 10 verification checks pass.
- README files cross-link and cover the four supported languages.
- `tests/fixtures/` contains all four verbatim samples + a placeholder for the compaction prompt.
- Plan is updated with "completed: YYYY-MM-DD" line at the bottom.
