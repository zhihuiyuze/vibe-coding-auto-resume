# 009: Agent adapter pattern (future support for Codex, Aider, etc.)

Status: draft

## Problem

The current v1 implementation is hardcoded to Claude Code:

- `lib/jsonl-stats.sh` reads `~/.claude/projects/<encoded-cwd>/*.jsonl` — a Claude-Code-specific path and file format.
- `config/grep-patterns.txt` carries Claude TUI verbatim wording (`5-hour limit reached ∙ resets 12pm`, etc.).
- `bin/vibe-run` invokes `claude --resume <uuid>` / `claude --continue` — Claude-specific flags.
- `bin/vibe-session-capture` watches the Claude JSONL directory.

But the project name (`vibe-coding-auto-resume`) and the umbrella CLI (`vibe`) were chosen agent-agnostic. The user plans to support other agentic CLIs (OpenAI Codex CLI, Aider, future tools) without renaming everything again.

This doc designs the adapter shape so v1 can be extended without rewriting the core flow.

## Constraints

- **Backward compatibility**: existing v1 users running `vibe run` must keep working with no flags (default agent = `claude`).
- **No new runtime deps**: stay bash + jq + curl.
- **Shared core**: `lib/llm-classify.sh`, `lib/tmux-pane.sh`, `shell/vibe.bash` should be agent-agnostic and not changed when adding an adapter.
- **Agent isolation**: anything Claude-specific (JSONL path, TUI wording, resume flags) moves into the adapter.
- **Per-agent test fixtures**: each adapter brings its own `tests/fixtures/<agent>/` so smoke tests cover them in isolation.

## Approach

### File layout

```
lib/
  adapters/
    claude.sh        — implements claude-specific operations
    codex.sh         — future
    aider.sh         — future
  jsonl-stats.sh     — kept; calls into the active adapter for JSONL location
  pane-grep.sh       — kept; pattern source becomes per-adapter
  llm-classify.sh    — unchanged (provider, not agent, concern)
  tmux-pane.sh       — unchanged
config/
  patterns/
    claude.txt       — current grep-patterns.txt renamed/moved here
    codex.txt        — future
shell/
  vibe.bash          — adds --agent flag plumbing on `vibe run`
bin/
  vibe-run           — reads VIBE_AGENT (env or --agent flag), sources the adapter
```

### Adapter contract

Each adapter exports a fixed set of functions:

```bash
# adapter_name() — short id, e.g. "claude", "codex"
adapter_name() { echo "claude"; }

# adapter_jsonl_dir() — where this agent writes its session JSONL
adapter_jsonl_dir() { echo "$HOME/.claude/projects/$(encoded_cwd)"; }

# adapter_patterns_file() — path to per-agent grep patterns
adapter_patterns_file() { echo "$VIBE_HOME/config/patterns/claude.txt"; }

# adapter_launch <args...> — first-cycle launch
adapter_launch() { exec claude "$@"; }

# adapter_resume <session_uuid> <args...>
adapter_resume() { exec claude --resume "$1" "${@:2}"; }

# adapter_continue <args...>
adapter_continue() { exec claude --continue "$@"; }

# adapter_session_id_from_jsonl <jsonl_path>
# Some agents may not use UUID-named files; let adapter compute it.
adapter_session_id_from_jsonl() { basename "$1" .jsonl; }
```

The wrapper sources the adapter once at startup based on `VIBE_AGENT` (env var) or `--agent <name>` (CLI flag, takes precedence).

### Dispatch in `vibe-run`

```bash
agent="${VIBE_AGENT:-claude}"
# parse leading --agent <name> before passing args through
if [[ "${1:-}" == "--agent" ]]; then
  agent="$2"; shift 2
fi
source "$VIBE_HOME/lib/adapters/${agent}.sh" \
  || die "unknown agent: $agent (lib/adapters/${agent}.sh missing)"
```

All subsequent calls go through `adapter_*` functions instead of hardcoded `claude` invocations.

### `vibe status` and `vibe work` impact

- `vibe status` reads from the active adapter's JSONL dir — change `lib/jsonl-stats.sh` to call `adapter_jsonl_dir` instead of hardcoding `~/.claude/projects`.
- `vibe work` is unchanged; entering tmux + sourcing `.env.local` is agent-agnostic.

### Per-agent fixtures

```
tests/fixtures/
  claude/
    5h-limit-1.txt
    weekly-opus-1.txt
    ...
  codex/
    rate-limit-1.txt   — when added
```

`tests/smoke.sh` iterates adapters and runs the L2 fixture pass against each adapter's pattern file.

## Alternatives considered

- **Plugin system with auto-discovery** (drop a file in `lib/adapters/` and it appears): overkill; explicit `--agent` flag is clearer and prevents accidents.
- **Run a different binary based on detected env** (auto-pick claude vs codex based on PATH): too magical; user should opt in explicitly.
- **One adapter file with `case` statements per-agent inside each function**: harder to test in isolation, encourages mixing concerns.
- **Use language other than bash for the adapter** (e.g. Python plugins): contradicts the zero-runtime-dep goal.

## API / file layout

New:
- `lib/adapters/claude.sh` — extract Claude-specific code from current files
- `lib/adapters/<future>.sh` — added per agent
- `config/patterns/claude.txt` — moved from `config/grep-patterns.txt`
- `config/patterns/<future>.txt` — added per agent

Changed:
- `bin/vibe-run` — adapter dispatch at startup
- `lib/jsonl-stats.sh` — call `adapter_jsonl_dir` instead of hardcoded path
- `lib/pane-grep.sh` — load patterns from `adapter_patterns_file`
- `shell/vibe.bash` — pass through `--agent` from `vibe run` to `vibe-run`

Env / flags:
- `VIBE_AGENT` env var — default agent (default `claude`)
- `--agent <name>` flag on `vibe run` — per-invocation override

## What NOT to implement

- **Do not** ship adapters for agents you can't actually test. Codex/Aider stubs would rot quickly. Wait until a user actually needs each one and can provide test fixtures.
- **Do not** auto-detect the agent from the user's environment. Explicit `VIBE_AGENT` or `--agent` only.
- **Do not** split `lib/llm-classify.sh` per agent. LLM provider (DeepSeek, OpenAI, etc.) is orthogonal to which agent is being wrapped.
- **Do not** rename `vibe-run` to per-agent variants (`vibe-claude-run`, `vibe-codex-run`). The whole point of the umbrella CLI is one entry point.
- **Do not** migrate v1 fixtures to `tests/fixtures/claude/` until at least one second adapter exists. Premature reorganization.

## Test plan

When the first non-Claude adapter lands:

- Unit: per-adapter fixture passes through L2 pattern matching.
- Unit: `adapter_jsonl_dir` returns a valid path for each adapter when invoked in a real cwd.
- Integration: `VIBE_AGENT=<x> vibe run` invokes the right CLI binary (stubbed in tests).
- Smoke: `tests/smoke.sh` iterates `lib/adapters/*.sh`, runs the per-agent fixture suite for each.

## Migration sequence

1. Move `config/grep-patterns.txt` → `config/patterns/claude.txt`.
2. Move `tests/fixtures/*.txt` → `tests/fixtures/claude/*.txt`.
3. Extract Claude-specific bits of `bin/vibe-run` and `bin/vibe-session-capture` into `lib/adapters/claude.sh`. Source it in the wrapper.
4. Add `VIBE_AGENT=claude` default everywhere; wire `--agent` flag plumbing.
5. Verify `tests/smoke.sh` still green.
6. Ship migration as a single release before adding a second adapter.
