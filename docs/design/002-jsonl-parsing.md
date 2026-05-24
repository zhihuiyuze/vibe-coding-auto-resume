# 002: JSONL parsing for L1

Status: accepted

## Problem

L1 (see [001](001-three-layer-detection.md)) needs to answer two questions cheaply, locally, with no external deps:

- How much of the current 5-hour block has the user already consumed?
- When does the current block end?

The `ccusage` npm package answers both, but pulling a runtime npm dep for ~50 lines of bash is excessive and creates a moving target. We do it ourselves.

## Constraints

- Pure bash + `jq`. No Python, no Node, no other interpreters.
- Defensive against schema drift — Anthropic may add/rename fields in JSONL without warning.
- Must work when the JSONL directory is empty (first-ever session).
- Output must be machine-parseable JSON for the wrapper to consume.

## Approach

### Data location

Claude Code writes one JSONL per session at:

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

Where `<encoded-cwd>` is the absolute working directory with `/` replaced by `-`. For example, `/home/alice/dev/my-project` becomes `-home-alice-dev-my-project`.

### Field assumptions

We assume each line is a JSON object with (at least) these fields:

```jsonc
{
  "timestamp": "2026-05-24T08:00:00Z",
  "message": {
    "usage": {
      "input_tokens": 123,
      "output_tokens": 456,
      "cache_read_input_tokens": 789,
      "cache_creation_input_tokens": 0
    }
  }
}
```

If a line lacks any of these, we use `// empty` in jq so the missing field becomes `0` instead of crashing the whole parse.

### Computation

- **Current session JSONL** = newest mtime in `~/.claude/projects/<encoded-cwd>/`.
- **Block tokens** = sum of `input + output + cache_read_input` across all turns in current JSONL (cache_creation excluded because Anthropic explicitly states it doesn't count against the rate limit; debatable, but matches user-facing burn perception).
- **Block start** = first message's `timestamp`.
- **Block end** = block_start + 5h.
- **Historical peak** = max block_tokens across all JSONL files in this and any sibling project dirs (or `CC_PEAK_FALLBACK` if none).
- **block_pct** = block_tokens / historical_peak, clamped to [0.0, 1.0].

### Output

`jsonl_stats` emits one JSON object:

```json
{"block_pct": 0.42, "block_end_iso": "2026-05-24T13:00:00Z", "peak": 198500}
```

## Alternatives considered

- **Use ccusage and parse its output**: extra dep, doesn't simplify anything, npm package is a moving target.
- **Use a Python script with `claude-monitor`-like parsing**: PEP 668 blocks `pip install` on user's system, pipx would add a second install step, defeats the "zero dep" goal.
- **Skip historical peak, hard-code a 200k cap**: peak self-adapts to user's pattern; hard-coded number is wrong for almost everyone.
- **Use cache_creation tokens too**: Anthropic explicitly excludes them from rate-limit accounting per recent docs.

## API / file layout

`lib/jsonl-stats.sh` (sourced module):

```bash
encoded_cwd()           # pwd | sed 's|/|-|g'
current_session_jsonl() # ls -t ~/.claude/projects/$(encoded_cwd)/*.jsonl | head -1
block_tokens()          # jq -s '[.[].message.usage|...] | add' over current JSONL
block_start_iso()       # jq -s 'first | .timestamp' over current JSONL
block_end_iso()         # block_start + 5h, via date
historical_peak()       # max block_tokens across all *.jsonl in all sibling dirs
jsonl_stats()           # composite JSON output
```

All functions tolerate missing inputs (return 0 / null / empty string rather than erroring).

## What NOT to implement

- **Do not** write JSONL files. We only read.
- **Do not** parse Anthropic's internal field names beyond `message.usage.{input,output,cache_read_input}_tokens`. If they add new fields we want, that's a separate design doc.
- **Do not** estimate dollar cost. Out of scope; ccusage-style $$$ reporting is not a goal here.
- **Do not** add cross-session aggregation beyond historical peak. Per-day, per-week views are for `ccusage` users; we want one number for one decision.
- **Do not** implement a watcher mode (notifying when usage crosses a threshold). That's [007 cap monitor](007-soft-cap-monitor.md)'s job; this module is pull-only.

## Test plan

- Unit: feed a synthetic JSONL with known token totals, assert `block_tokens` returns the sum.
- Edge: empty directory → `jsonl_stats` returns `{block_pct: 0.0, block_end_iso: null, peak: CC_PEAK_FALLBACK}` without erroring.
- Edge: malformed line (truncated JSON) → that line is skipped, others still sum.
- Smoke: against the user's real `~/.claude/projects/*` data, output looks sane (block_pct between 0 and 1, block_end_iso a valid future-or-past timestamp).
