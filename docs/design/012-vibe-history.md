# 012: `vibe history` — list Claude Code sessions for a project

Status: accepted

## Problem

To resume a specific past Claude conversation, users currently have to:
- `ls -t ~/.claude/projects/<encoded-cwd>/*.jsonl` (memorize the path-encoding rule)
- `jq` each candidate to peek at the last user message
- Read filename mtimes to guess recency

README scenario 2 documents this as a workaround. Making it a first-class
subcommand lowers friction and removes the need to remember the encoding
rule.

`vibe ls` is unrelated — that lists **live tmux sessions**. This command
lists **historical Claude conversations on disk**. Different domains;
keep them as separate subcommands.

## Constraints

- No new runtime dependencies. Already-required `jq`, `stat`, `bash`.
- Read-only. Must never modify, move, or rename JSONL files.
- Default to `$PWD`; allow `--cwd PATH` to query a different project.
- Pipe-friendly: `--json` mode for scripts.

## Approach

New binary `bin/vibe-history`.

Resolves encoded path = `$PWD` (or `--cwd`) with `/` → `-`. Reads
`${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/<encoded>/*.jsonl` sorted
by mtime (newest first). For each file:

- `uuid` = filename minus `.jsonl`
- `mtime` = `stat -c %y` truncated to seconds
- `msgs` = `wc -l` (each JSONL line is one message turn)
- `last_user_message` = last line matching `.message.role == "user"`,
  extract `.message.content[0].text` (or the string content directly),
  truncated to 80 chars, newlines stripped

Output modes:

- **default** (table) — one row per session, fixed columns:
  `mtime msgs UUID last_user_message`
- **`--json`** — JSON array of `{uuid, mtime, msgs, last_user_message}`
  objects, suitable for `jq` piping

Flags:

| flag | default | purpose |
|---|---|---|
| `--limit N` | `10` | show only N most recent; `0` = unlimited |
| `--json` | off | emit JSON array instead of table |
| `--cwd PATH` | `$PWD` | query a different project |
| `--help`, `-h` | — | usage |

Empty result (no JSONL dir / no files) → friendly stderr message + exit 0.

`shell/vibe.bash` gains a `history` subcommand that delegates to
`vibe-history` via the same fallback chain as `run` / `status`.

`install.sh` and `uninstall.sh` add `vibe-history` to the symlink loop.

## Alternatives considered

- **Extend `vibe ls` with `--history`.** Rejected — `vibe ls` is tmux
  topology; this is JSONL history. Conflating the two domains under one
  command makes the output ambiguous and the flag surface hostile.
- **Interactive picker that runs `--resume` on selection.** Out of scope
  for v1; copy/paste of UUID is fine. Could add later via fzf/dialog if
  there's demand.
- **Show token / cost columns from L1.** Belongs in `vibe status` — that
  command is the one focused on usage. `vibe history` answers "what was
  this session about", not "how much did it burn".
- **Cross-project mode (`--all` to dump every project's sessions).**
  Out of scope; the user can `ls ~/.claude/projects/` themselves.
- **Reverse-tail optimization** (read only last N lines of large
  JSONLs). Skipped for v1 — even 10MB JSONLs scan in <100ms on the
  target hardware. Optimize if it ever becomes painful.

## API / file layout

New / changed:

- `bin/vibe-history` — new executable.
- `shell/vibe.bash` — register `history` subcommand; update `_vibe_help`.
- `install.sh` — add `vibe-history` to the symlink loop.
- `uninstall.sh` — add `vibe-history` to the removal list.
- `tests/smoke.sh` — fixture-driven test (stage synthetic JSONLs, assert
  table format, JSON validity, `--limit`).
- `tests/install-test.sh` — assert the new symlink lands on install and
  is removed on uninstall.
- `docs/design/README.md` — index entry for 012.
- README × 4 langs + site × 4 locales — short reference in scenario 2.

No new env vars. Honors existing `CLAUDE_PROJECTS_DIR` override (already
used by `lib/jsonl-stats.sh`).

## What NOT to implement

- Cross-project listing (`--all` / no-cwd mode). User can browse the
  parent dir themselves.
- Filtering by date range, regex search on content, etc. Defer until
  a real use case shows up.
- Auto-launching `vibe run --resume` from the listing. Copy/paste UUID
  is fine.
- Token or cost columns. Belongs in `vibe status`.
- Deleting / renaming sessions. Strictly read-only.
- Cross-machine queries (e.g. over SSH). Out of scope.

## Test plan

- **Unit / integration (smoke.sh)**:
  - Stage `$CLAUDE_PROJECTS_DIR/<encoded>/` with 2 synthetic JSONLs
    carrying distinct user messages and different mtimes.
  - Run `vibe-history` with `--cwd` pointing at the staged project.
  - Assert: 2 rows, both UUIDs appear, newer one first.
  - Assert: `--json` mode emits a valid JSON array of length 2.
  - Assert: `--limit 1` caps to one row.
  - Assert: querying a directory with no JSONLs prints the "no
    sessions" message and exits 0.

- **Install regression (install-test.sh)**:
  - Symlink lands at `~/.local/bin/vibe-history` after install.
  - Symlink removed after uninstall.

- **Manual sanity**:
  - Real `vibe history` from inside this repo's own claude project dir
    returns expected rows.
