# Implementation plans

Plans translate accepted designs (see [`../design/`](../design/)) into concrete, sequenced work. One plan per release tier.

## Index

| Plan | Status | Covers |
|---|---|---|
| [v1-mvp.md](v1-mvp.md) | active | First shippable wrapper: L1+L2+L3, pre-flight, resume, post-resume detect-and-warn |
| [v2-cap-monitor.md](v2-cap-monitor.md) | future | Soft-cap mid-run prompt injection, HANDOFF.md verification |

## Template

```markdown
# vN: <Title>

## Goal

What this release tier delivers in one sentence.

## Designs implemented

- [00X](../design/00X-name.md) — short reminder
- [00Y](../design/00Y-name.md) — short reminder

## Phases

### Phase A: <name>
- Step
- Step

### Phase B: <name>
- Step
- Step

## Verification

- Test or check
- Test or check

## Done definition

What "shipped" means for this tier — a checklist the implementer can sign off.
```
