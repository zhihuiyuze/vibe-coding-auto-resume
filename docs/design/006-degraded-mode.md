# 006: Degraded mode contract

Status: accepted

## Problem

The wrapper must remain useful when no LLM provider is available. We've already decided L3 is opt-in (see [005](005-llm-provider-abstraction.md)), so this design fixes the exact behavior when L3 is disabled — what works, what doesn't, and how the user knows which is which.

The risk this guards against: a user installs the wrapper without configuring an API key, hits a rate limit, and the wrapper silently does the wrong thing because L1+L2 alone can't resolve the ambiguity. We need an explicit contract so the failure modes are predictable.

## Constraints

- No silent misclassification. If we're uncertain, refuse to auto-resume.
- User must be told, clearly, that they're in degraded mode and what to do to upgrade.
- Performance budget: degraded mode must not be slower than full mode (no useless retries).

## Approach

### Determining degraded mode

`l3_enabled = (CC_LLM_PROVIDER != "none" && detect_provider() returns non-empty)`

Set once at wrapper start. Logged on first action.

### Pre-flight behavior

| L1 result | L2 warning grep | L3 enabled? | Decision |
|---|---|---|---|
| `block_pct < 0.60` | (not checked) | n/a | Proceed |
| `0.60 <= block_pct < CC_USAGE_THRESHOLD` | no hit | n/a | Proceed (silently) |
| `0.60 <= block_pct < CC_USAGE_THRESHOLD` | hit | **enabled** | Run L3; if `warning` → refuse |
| `0.60 <= block_pct < CC_USAGE_THRESHOLD` | hit | **disabled** | Print warning, proceed (don't block) |
| `block_pct >= CC_USAGE_THRESHOLD` | (not checked) | n/a | Refuse with `Block at <pct>%, reserving budget` |

Degraded mode is conservative on the high end (still refuses above threshold from L1 alone) and permissive in the ambiguous middle band (proceeds with a printed warning rather than blocking).

### Post-exit behavior

| L2 limit grep | L2 reset_time extract | L3 enabled? | Decision |
|---|---|---|---|
| no hit | n/a | n/a | Exit with original exit code (treat as normal/real error) |
| hit | succeeded | **enabled** | L3 confirms classification + may override reset_time → sleep + resume |
| hit | succeeded | **disabled** | Log `[degraded mode] L2 matched limit + extracted reset; resuming without LLM confirmation` → sleep + resume |
| hit | failed | **enabled** | L3 attempts to classify + extract reset → resume or refuse based on L3 |
| hit | failed | **disabled** | Refuse with `Limit keywords detected but reset time unparsed. Set DEEPSEEK_API_KEY to enable L3 LLM. Exiting without resume.` |

The last row is the critical safety case: L2 saw a limit-like string but couldn't parse a time, and we have no LLM to figure it out. **Refuse rather than guess.**

### User messaging

Every degraded-mode decision prints a marked line so the user can tell what happened:

```
[degraded mode] L2 matched limit + extracted reset; resuming without LLM confirmation.
[degraded mode] L2 matched but reset_time unparsed. Set DEEPSEEK_API_KEY for L3. Not resuming.
```

The installer prints, when no key is detected:

```
No API key found. Running in L1+L2 mode (zero external calls).
Set DEEPSEEK_API_KEY (or ANTHROPIC_API_KEY / OPENAI_API_KEY / OLLAMA_HOST)
and re-run install.sh to enable L3 for better detection accuracy.
```

## Alternatives considered

- **Always refuse in ambiguous mid-band when L3 is disabled**: too conservative; user gets blocked at 60% for no clear reason.
- **Always proceed in ambiguous mid-band when L3 is disabled**: too permissive; user might cross the threshold during the session.
- **Add an "L2.5" with smarter regex parsing**: just moves L3 logic into L2 with worse precision. Punted.
- **Make L3 mandatory (require API key at install time)**: defeats the "zero dep core" goal.

## API / file layout

No new files. Updates to `bin/vibe-run`:

- Single `l3_enabled` boolean computed at startup.
- Branches in pre-flight and post-exit sections key on it.
- Print prefix `[degraded mode]` on all degraded-path log lines.

## What NOT to implement

- **Do not** add a "warn-only" partial L3 mode that gets called but ignored. Either fully use L3 or don't.
- **Do not** suppress the `[degraded mode]` log lines. Visibility is the point.
- **Do not** allow `CC_USAGE_THRESHOLD` to be overridden when L3 is disabled. Same threshold in both modes; the difference is only what happens in the ambiguous band.
- **Do not** auto-install an API key for the user (e.g., prompt to register for DeepSeek). Not our job.

## Test plan

- Unit: each table row above has a test case in `smoke.sh` — mock the relevant signals, assert the right decision is taken.
- Unit: degraded-mode log lines are emitted with the `[degraded mode]` prefix.
- Integration: unset all `*_API_KEY` env vars, run wrapper with a fixture that exits with the "limit + no parseable reset" combo, assert refusal.
