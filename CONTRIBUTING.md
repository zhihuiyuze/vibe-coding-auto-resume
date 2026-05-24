# Contributing

Thanks for your interest. Project conventions, architecture, and the spec-first
workflow live in **[AGENTS.md](AGENTS.md)** — start there.

Short version:

1. For any change beyond a typo or a single-line bugfix, open a PR that **adds
   or updates a design doc** in `docs/design/00X-<name>.md` from the template
   in [`docs/design/README.md`](docs/design/README.md). Code review follows the
   accepted design.
2. Run the tests locally before opening the PR:
   ```bash
   bash tests/smoke.sh
   bash tests/install-test.sh
   ```
3. Follow the conventions in AGENTS.md (English source, no AI-attribution
   markers, marker-blocked rc edits, etc.).

## Reporting issues

- TUI wording changes (Claude Code releases sometimes alter rate-limit phrases):
  open an issue with the verbatim text and save it as `tests/fixtures/<name>.txt`
  for regression tests.
- Adapter requests (Codex / Aider / other agentic CLIs): see
  [`docs/design/009-agent-adapters.md`](docs/design/009-agent-adapters.md) and
  open a PR with an adapter doc + implementation.

## Security

Don't include real secrets in commits. The repo's `.gitignore` blocks the
obvious patterns; if you accidentally commit a key, rotate it before opening
the PR.
