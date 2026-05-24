# Design docs

This directory holds **one design doc per feature**. Design docs are the source of truth for what gets built; code follows.

## Workflow

1. Copy the template below into `00X-<kebab-name>.md` (next free number).
2. Fill out all sections. The "What NOT to implement" section is required, not optional.
3. Open a PR with just the doc. Get review on direction before writing code.
4. Once accepted (status: `accepted`), implement.
5. Reference the doc in your commit: `feat(<scope>): <summary> (docs/design/00X)`.
6. Update status to `implemented` once the code is merged.
7. If a later design replaces this one, set status to `superseded by 0YY` and link.

## Index

| # | Title | Status | Tier |
|---|---|---|---|
| 001 | [Three-layer detection](001-three-layer-detection.md) | accepted | v1 |
| 002 | [JSONL parsing for L1](002-jsonl-parsing.md) | accepted | v1 |
| 003 | [Session-id capture](003-session-capture.md) | accepted | v1 |
| 004 | [Resume vs continue strategy](004-resume-vs-continue.md) | accepted | v1 |
| 005 | [LLM provider abstraction](005-llm-provider-abstraction.md) | accepted | v1 |
| 006 | [Degraded mode contract](006-degraded-mode.md) | accepted | v1 |
| 007 | [Soft-cap monitor](007-soft-cap-monitor.md) | draft | v2 |
| 008 | [Post-resume compaction handling](008-post-resume-compaction.md) | accepted | v1 |
| 009 | [Agent adapter pattern (Codex/Aider/...)](009-agent-adapters.md) | draft | future |

## Template

```markdown
# 00X: <Title>

Status: draft

## Problem

What gap, bug, or unmet need is driving this? Why now?

## Constraints

Hard limits the design must respect (deps, perf, security, env).

## Approach

The chosen design, described concretely. Include diagrams or pseudo-code as needed.

## Alternatives considered

Other designs we evaluated and rejected, with the rejection reason.

## API / file layout

What new or changed files, functions, env vars, config keys. Names matter.

## What NOT to implement

Scope boundaries. Things adjacent or tempting that this doc explicitly does NOT cover. (Required: agents will overreach without this.)

## Test plan

How we verify the implementation works end-to-end.
```

## Status lifecycle

- `draft` — being written or reviewed; do not implement yet.
- `accepted` — reviewed and approved; safe to implement.
- `implemented` — code is merged; doc is now historical reference.
- `superseded by 0YY` — replaced by a newer design; link the successor.

## Conventions

- One feature = one doc. If a doc starts sprawling, split it.
- Filename: `00X-<kebab-name>.md`. Numbers are append-only (never re-number).
- Keep docs evergreen as code evolves — when behavior changes, update the doc *in the same PR*.
- Cross-reference siblings inline with relative links (`[L2 uses these patterns](002-jsonl-parsing.md#patterns)`).
