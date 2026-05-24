# 001: Three-layer detection

Status: accepted

## Problem

The wrapper needs to know **why** `claude` exited so it can decide whether to auto-resume:

- **Rate-limit hit** → sleep until reset, then resume.
- **Approaching warning** → don't auto-continue; preserve interactive budget.
- **Real error** (crash, MCP failure, tool denied, network) → exit, don't loop.
- **Normal exit** (user typed `/exit`, task done) → exit cleanly.

Prior tools either trusted exit codes (false positives on every crash) or scraped TUI text with brittle regex (broke whenever Anthropic tweaked wording). We need something that doesn't break on the next Claude Code release.

## Constraints

- Must work out of the box with no API key.
- Must not silently misclassify — a wrong "limit_hit" decision leads to a sleep-and-resume loop on a crashing session.
- Must add at most one external dep beyond `jq`/`curl`/`tmux` (which are baseline assumed).
- Privacy: any data sent off-machine must be opt-in with an explicit prompt.

## Approach

Three layers, evaluated in order. Each one is fast enough that running them all costs negligible time.

### L1 — JSONL stats (deterministic, local)

`lib/jsonl-stats.sh` reads `~/.claude/projects/<encoded-cwd>/*.jsonl` directly. Anthropic's CLI writes one JSONL entry per turn, including `message.usage.{input,output,cache_read_input}_tokens`. We sum the current session's tokens, derive the 5-hour block window from the first message timestamp, and compute a historical peak across all past blocks to estimate "100%".

**Output**: `{block_pct, block_end_iso, peak}`.

**Used for**: pre-flight refusal when block already above `CC_USAGE_THRESHOLD` (default 0.75), v2 cap-monitor periodic polling.

### L2 — Pane grep (deterministic, local)

`lib/pane-grep.sh` runs `tmux capture-pane -p` on the `claude` pane, tails the last 30 lines, and matches verbatim Claude TUI strings (see [002](002-jsonl-parsing.md) and `config/grep-patterns.txt`):

- `5-hour limit reached ∙ resets 12pm`
- `Opus weekly limit reached ∙ resets Oct 31, 9am`
- `Approaching 5-hour limit`
- `Claude usage limit reached. Your limit will reset at 3pm (America/Santiago).`

Note `∙` is U+2219 BULLET OPERATOR, not the common `•` (U+2022). Patterns match both defensively.

**Output**: `0`/`1` per group; `extract_reset_time` parses the time string into ISO 8601.

**Used for**: post-exit triage (does the tail look like a rate-limit hit?), pre-flight warning probe (is Anthropic already showing an "approaching" yellow tag?).

### L3 — LLM classifier (opt-in, network)

`lib/llm-classify.sh` sends the redacted pane tail to a chosen LLM (DeepSeek / Claude Haiku 4.5 / OpenAI gpt-4o-mini / Ollama) and receives back structured JSON:

```json
{"status": "limit_hit|warning|error|normal_exit|running",
 "reset_time": "2026-05-24T18:30:00Z or null",
 "idle": true,
 "modal_open": false,
 "reasoning": "one sentence"}
```

Provider auto-selected from env vars (priority: `CC_LLM_PROVIDER` > `DEEPSEEK_API_KEY` > `ANTHROPIC_API_KEY` > `OPENAI_API_KEY` > `OLLAMA_HOST`). On network failure or non-JSON response, returns `status=error` (safe default — wrapper won't auto-resume).

**Used for**: confirming ambiguous L2 hits (e.g., L2 saw "limit" but in a code comment), extracting reset time when L2 regex couldn't parse it (new wording variants), v2 cap-monitor `idle && !modal_open` gating for safe tmux send-keys injection.

## Alternatives considered

- **Exit code only**: Rejected. `claude` exits `1` on rate-limit but also on crashes / MCP failures / etc. Indistinguishable.
- **Regex only (terryso/claude-auto-resume route)**: Rejected. The exact reason this project exists — Anthropic changes TUI wording, regex breaks (GH issue #24).
- **LLM only**: Rejected. Forces external API dep, sends pane content for every check, privacy concern for users in sensitive codebases, costs add up.
- **ccusage as L1**: Rejected. Pulls a moving npm package as a runtime dep; we can do the same JSONL parsing in 50 lines of bash + jq with no install footprint.

## API / file layout

New:
- `lib/jsonl-stats.sh` — sourced module
- `lib/pane-grep.sh` — sourced module
- `lib/llm-classify.sh` — sourced module
- `config/grep-patterns.txt` — editable patterns
- `config/classify-prompt.txt` — LLM system prompt

Env vars:
- `CC_LLM_PROVIDER` — `deepseek`/`claude`/`openai`/`ollama`/`none`. Default: auto-detect from key env vars; `none` forces L1+L2 only.
- `CC_LLM_MODEL` — override per-provider default model.
- `CC_USAGE_THRESHOLD` — pre-flight refusal threshold. Default `0.75`.
- `CC_PANE_TAIL_LINES` — capture-pane tail length. Default `30`.
- `CC_LLM_REDACT` — basic secrets masking. Default `1`.
- `CC_PEAK_FALLBACK` — L1 100% fallback when no history. Default `200000`.

## What NOT to implement

- **Do not** add a "L4" or any more layers. Three is already the ceiling for cognitive load.
- **Do not** make L3 a hard dependency. The tool must remain useful with no API key.
- **Do not** cache LLM responses to disk. The pane content is privacy-sensitive; transient memory is fine.
- **Do not** parse Anthropic's TUI output beyond what `config/grep-patterns.txt` does. If a new pattern is needed, add a line to that file — don't write custom regex in `pane-grep.sh`.
- **Do not** implement automatic provider fallback (e.g. "try DeepSeek then OpenAI"). One provider per session keeps cost predictable.

## Test plan

- `tests/smoke.sh`:
  - L1: feed a JSONL fixture, assert `jsonl_stats` returns expected `block_pct`.
  - L2: feed each `tests/fixtures/*.txt` to `pane_grep`, assert the right group matches.
  - L3: stub `curl` to return canned JSON, assert wrapper takes the right branch.
- Integration: simulate a "limit_hit" exit (mock the pane), assert wrapper sleeps + invokes `claude --resume`.
- Real-API: when keys present, send each fixture through each provider, assert structured response matches expected status.
