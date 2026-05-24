<!-- === vibe-coding-auto-resume: long-task continuity rules === -->

## Long-task continuity (HANDOFF.md)

This project uses `HANDOFF.md` as a cross-session continuity file. The session you are in
may be the result of an automatic resume after a rate-limit reset; a new session may take
over from yours if you are interrupted.

- **At session start**: read `HANDOFF.md` before doing anything else. It tells you what
  the prior session was working on, what's done, what's next, and what's blocked.
- **After every milestone** (test passes, feature complete, bugfix landed): immediately
  update `HANDOFF.md`. Don't batch.
- **If interrupted** (rate-limit warning, asked to wrap up): your final action before
  exiting must be updating `HANDOFF.md`.

`HANDOFF.md` sections (keep all five, even when empty):

- **Current task** — one paragraph on what you're doing now
- **Completed** — milestones with `[YYYY-MM-DD HH:MM]` timestamps
- **Next steps** — ordered, most important first
- **Blockers** — open questions, pending human decisions, stuck dependencies
- **Context** — key decisions, file paths, commands, config choices

## Auto-resume awareness

If you see a "save progress to HANDOFF.md" message arrive in your input out of nowhere,
that is the soft-cap monitor protecting the user's remaining block budget. Treat it as
high priority: stop the current task, update `HANDOFF.md` accurately, then call /exit.
The next session will pick up from `HANDOFF.md`.

<!-- === end vibe-coding-auto-resume === -->
