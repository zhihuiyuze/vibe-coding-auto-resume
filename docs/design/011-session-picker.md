# 011: Session discovery (`vibe ls`) + smart `vibe work`

Status: accepted

## Problem

`vibe work` (no args) derives the session name from a `cksum` hash of
`$PWD`. This is convenient but brittle in three ways:

1. **The session is bound to the cwd it was created in.** If you run
   `vibe work` from a slightly different path (e.g. `~/dev/project` vs
   a symlink at `~/project`, or after a directory rename), you create a
   second session that shares no state with the first.
2. **Users have no way to see what's there.** "Is my project's vibe
   session still alive?" currently means `tmux ls` and squinting at
   names like `vibe-boldfox` to figure out which one is yours.
3. **No way to pick between siblings.** If you legitimately have two
   vibe sessions for the same project (e.g. one for `feature-x` and one
   for `bugfix`), `vibe work` from the project root deterministically
   picks the hash-named one, not the named ones you actually want.

## Constraints

- Must remain a shell function (no extra binary), because it modifies
  the caller's terminal via `tmux attach`.
- Must work in bash; vibe.bash is sourced from `~/.bashrc`.
- Non-interactive callers (scripts, CI) must not block on a picker
  prompt — degrade to a printed list + non-zero exit.
- Existing `vibe work <name>` behavior must not change.

## Approach

Two related, separable features:

### `vibe ls` (new subcommand)

Lists every `vibe-*` tmux session with its current pane cwd and
attached state. Marks sessions whose cwd matches `$PWD` with `← here`.
Read-only; takes no arguments.

```
$ vibe ls
  vibe-boldfox              /home/huize/dev/projectA  ← here  [attached]
  vibe-feature-x            /home/huize/dev/projectA  ← here
  vibe-quietowl             /home/huize/dev/scratch
```

### Smart `vibe work` (no args)

Look up all vibe-* sessions whose first pane's `pane_current_path`
equals `$PWD`:

- **0 matches** → existing behavior: cd to `${VIBE_PROJECT_ROOT:-$PWD}`,
  create/attach session named by cwd-hash.
- **1 match** → attach to that session directly (regardless of whether
  its name matches the cwd-hash).
- **N matches** → numbered picker on stdin:
  ```
  vibe: 2 sessions match /home/huize/dev/projectA
    1) vibe-boldfox
    2) vibe-feature-x
    n) new session
  pick [1-2/n]:
  ```
  - `1..N` → attach to that one
  - `n` → fall through to the existing cwd-hash create path
  - empty / anything else → abort with non-zero exit

If stdin is not a TTY (script/CI), skip the prompt entirely: print the
list to stderr and exit non-zero. Forces explicit naming in
non-interactive contexts.

`vibe work <name>` is unchanged — explicit name always wins, no
discovery, no picker.

## Why pane_current_path

tmux doesn't store the cwd a session was created in. What it does
expose is `#{pane_current_path}` — the cwd of the foreground process
in a given pane. For a vibe session this is:

- The shell's cwd when the pane is idle (typically the project root,
  since vibe work cd's there at create time and most users don't cd
  elsewhere inside)
- Claude's cwd when `vibe run` is active (== project root for normal
  use of vibe run)

So in practice this matches "the project this session belongs to."
The edge case (user cd'd elsewhere inside the pane) is rare and
self-inflicted; the user can still `vibe work <name>` explicitly.

We read only the **first pane** of the session for simplicity. Sessions
with multiple panes whose cwds disagree are unusual and not worth the
complexity here.

## Alternatives considered

- **Match by tmux's saved environment** (e.g. a `VIBE_PROJECT_ROOT`
  env var on the session). Rejected: requires changes to session
  creation to pin a value that doesn't naturally exist; pane_current_path
  is observable now without schema additions.
- **Fuzzy matching (subdir / ancestor of $PWD)**. Rejected for v1:
  ambiguous semantics (which ancestor wins?), high false-positive risk
  on broad paths like `~/dev`. Exact match is predictable.
- **Auto-attach to single match without confirmation in interactive shells;
  always print the list otherwise.** Rejected: divergence between
  modes is more surprising than helpful. Auto-attach on single match is
  fine because the user invoked `vibe work` — they asked to enter a
  vibe session.
- **TUI picker (fzf, dialog)**. Rejected: extra dependencies; the bash
  `read` prompt is enough for ≤9 candidates (we already cap discovery
  visually — users with many sessions will refactor or name them).

## API / file layout

Touched files:

- `shell/vibe.bash`
  - New: `_vibe_sessions_matching_cwd <path>` — emit names, one per line.
  - New: `_vibe_ls` — formatted listing of all vibe-* sessions.
  - Modified: `_vibe_work` — pre-flight discovery + picker when no
    explicit name and matches exist.
  - Modified: `vibe()` dispatcher — register `ls` subcommand.
  - Modified: `_vibe_help` — document the new behavior.

- `tests/smoke.sh`
  - New section: shim a fake `tmux` on PATH, exercise
    `_vibe_sessions_matching_cwd` with 0/1/N matches.

No new env vars. No new files in `bin/` or `lib/`.

## What NOT to implement

- Auto-killing or auto-cleaning sessions (`vibe rm`, `vibe gc`). Out of
  scope. Users can `tmux kill-session -t vibe-<name>` themselves.
- Fuzzy / subdirectory cwd matching. Strict equality only in v1.
- A picker for `vibe work <name>` (explicit name). Explicit always wins.
- Persistent picker UI (TUI library, fzf integration). Plain `read` only.
- Listing non-vibe-* tmux sessions. Out of scope; users have `tmux ls`.
- Showing block usage / claude session state in `vibe ls`. That's what
  `vibe status` is for; `vibe ls` is about tmux topology.
- Cross-host listing. Local tmux only.

## Test plan

- **Unit**: stub `tmux` on PATH that returns canned `list-sessions` and
  `display-message` output. Test:
  - 0 vibe-* sessions → empty output
  - 1 vibe-* session matching $PWD → name returned
  - 1 vibe-* session NOT matching → empty
  - Mixed vibe-* + non-vibe-* → only vibe-* returned
  - Multiple matches → multiple names, deterministic order

- **Integration (manual, documented)**:
  - From a project dir with no vibe sessions: `vibe work` → creates one,
    enters tmux normally
  - Detach (`Ctrl+b d`), re-run `vibe work` → "attaching" message,
    immediate reattach
  - Create a 2nd session: `vibe work feature-x`, detach
  - From project dir, `vibe work` → picker with 2 entries
  - Pick `1` → attaches to first; pick `n` → creates new cwd-hash one

- **Regression**: existing smoke tests (vibe-run/lib/etc) unaffected.
