# vibe-coding-auto-resume

Wrap the Claude Code CLI in tmux so long agentic tasks survive rate-limit hits, SSH disconnects, and overnight runs — without you babysitting the reset clock.

[***English***](README.md) | [中文](README.zh.md) | [Français](README.fr.md) | [Русский](README.ru.md)

## Install (one time)

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # only if missing — installer tells you
source ~/.bashrc
```

The installer is idempotent. It symlinks `vibe-run`, `vibe-status`, `vibe-session-capture` into `~/.local/bin/`, drops a `vibe` shell function into `~/.bashrc`, and appends a tmux config snippet. It never touches `~/.claude/` and never uses `sudo` on your behalf.

---

## Three scenarios — pick the one that matches your situation

### 1. I'm starting a new Claude task

```bash
cd ~/dev/<your-project>
vibe work                  # cd here + open a named tmux session
vibe run                   # this replaces `claude` — same flags, same UI
```

Now use Claude normally. When the 5-hour block is exhausted, `vibe run` notices, sleeps until the reset, and re-launches the **same session UUID** automatically. If Anthropic's new interactive modal appears (`What do you want to do? 1. Stop and wait …`), the wrapper picks the safe "Stop and wait" option for you.

To leave the session running and come back later: `Ctrl+b d`. To get back in: `vibe work`.

### 2. I want to resume a session I started earlier

If you remember the session UUID (from `~/.claude/projects/`, or copied out of a previous run's log):

```bash
cd ~/dev/<your-project>
vibe work
vibe run --resume <session-uuid>
```

If you don't remember it but it's the most recent session in that project:

```bash
vibe work
vibe run --mode continue                    # same as `claude --continue`, with auto-resume on rate-limit hit
```

To list candidates, peek at the JSONL filenames:

```bash
ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g')/*.jsonl | head -5
# the filename minus `.jsonl` is the session UUID
```

### 3. I'm working over SSH and the connection drops

The tmux session keeps running even after SSH dies — your `claude` process is owned by tmux, not by your shell. Step-by-step recovery:

```bash
ssh you@server                              # 1. reconnect
tmux ls                                     # 2. is your vibe-* session still alive?
                                            #    expected: e.g. "vibe-default: 1 windows (...)"
vibe work                                   # 3. re-attach (or `vibe work <name>` if you used a name)
                                            #    you land exactly where you left off
```

Once re-attached, scroll up to see what happened during your absence: `Ctrl+b [`, then PageUp / arrows, `q` to exit scrollback. If a rate limit hit while you were gone, the wrapper already handled it — you'll see the `[vibe-run] Sleeping … until …` and resume entries.

**Peek without attaching** (e.g. from another machine, just checking status):

```bash
ssh you@server "tmux ls"                                              # what's alive
ssh you@server "tmux capture-pane -t vibe-default -p | tail -50"      # last 50 pane lines
ssh you@server "vibe status"                                          # current block usage
```

**If `tmux ls` says `no server running`** — the host rebooted, or tmux was OOM-killed. The tmux session is gone, but Claude's JSONL history isn't. Use Scenario 2 above (`vibe run --resume <uuid>` or `vibe run --mode continue`) to pick up where you left off.

---

## Discover & juggle sessions

`vibe ls` shows every `vibe-*` tmux session with its current cwd, attached state, and a `← here` mark when the cwd matches yours:

```
$ vibe ls
  vibe-boldfox              /home/u/dev/projectA  ← here  [attached]
  vibe-feature-x            /home/u/dev/projectA  ← here
  vibe-quietowl             /home/u/dev/scratch
```

`vibe work` without arguments now uses this discovery before defaulting to the cwd-hash name:

- **0 matches** → creates a new session (cwd-hash name).
- **1 match** → attaches directly, no prompt.
- **N matches** → interactive picker (`1..N` to pick, `n` for a new one).

Explicit `vibe work <name>` skips discovery — the name always wins.

**Naming tip**: for projects you'll touch repeatedly, give the session an explicit name (`vibe work projectA`) instead of letting the cwd hash pick. It survives path changes (renames, symlinks) and is recognizable in `vibe ls` output.

---

## Optional: smarter detection via LLM

L1 (JSONL parsing) and L2 (tmux pane regex) cover the common rate-limit shapes with zero external calls. To handle TUI wording changes and edge cases — and to extract reset times the regex misses — opt into L3:

```bash
echo 'DEEPSEEK_API_KEY=sk-...' >> ~/.config/vibe/env   # chmod 600, created by installer
chmod 600 ~/.config/vibe/env
source ~/.bashrc
```

Supported providers: **DeepSeek** (cheapest, ~$0.05/block), **Anthropic Claude Haiku**, **OpenAI gpt-4o-mini**, **Ollama** (local, `[untested]` — needs GPU validation).

**Privacy**: with L3 on, the last ~30 pane lines (conversation tail + visible file previews) are sent to your chosen provider for a single classification call per limit event. Basic secret redaction (`sk-*`, `Bearer *`, `*_SECRET=*`, long base64) is on by default but is not a guarantee. Decline the opt-in (or `vibe run --no-l3`) to stay fully local.

---

## What's going on under the hood

When `claude` exits, `vibe run` runs three checks in order:

- **L1** sums `message.usage.{input,output,cache_read}_tokens` across the current project's JSONL files to know how much of the 5-hour block is burned and when it resets.
- **L2** runs `tmux capture-pane` and greps the tail for verbatim TUI strings (`5-hour limit reached ∙ resets …`, `weekly limit reached`, `Approaching 5-hour limit`, plus the new interactive modal "Stop and wait for limit to reset"). It extracts the reset clock-time.
- **L3** (opt-in) sends the same tail to an LLM and gets back `{status, reset_time, idle, modal_open}` for the cases L2 can't parse.

When `claude` exits cleanly or with a real error (crash, MCP failure, /exit), the wrapper exits with the same code — it does **not** blindly retry. Auto-resume fires only when a rate-limit signal is positively detected. See [`docs/architecture.md`](docs/architecture.md) and [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md) for the full rationale.

## CLI flags

```
vibe run [...args]
  --resume <uuid>          resume a specific session (used for all cycles)
  --threshold <0..1>       opt-in soft cap (default off — burn the block)
  --max-cycles <n>         resume cycles per invocation (0 = unlimited, default 1)
  --mode auto|session-id|continue
  --provider deepseek|claude|openai|ollama
  --no-l3                  force L1+L2 only
  --dangerously-skip-permissions
  -p "prompt"
  ... any other flag passes straight to claude
```

## Env vars (the main ones)

| Variable | Default | Purpose |
|---|---|---|
| `CC_LLM_PROVIDER` | auto-detect | `deepseek` / `claude` / `openai` / `ollama` / `none` |
| `CC_USAGE_THRESHOLD` | _unset_ (off) | Opt-in soft cap (e.g. `0.80`) to reserve interactive budget |
| `CC_RESUME_MODE` | `auto` | `auto` / `session-id` (strict UUID) / `continue` |
| `CC_RESUME_MAX_CYCLES` | `1` | `0` = unlimited resume cycles per invocation |
| `CC_SLEEP_PAD` | `60` | Seconds added to reset time before re-launching |

Less-common knobs (`CC_LLM_REDACT`, `CC_PANE_TAIL_LINES`, `CC_MODAL_POLL_INTERVAL`, …) are documented at the top of `bin/vibe-run`.

## Multi-session

`vibe work <name>` creates an isolated tmux session + state dir. Use it to run multiple Claude tasks side by side:

```bash
vibe work feature-a    # tmux session "vibe-feature-a"
# Ctrl+b d, then in another shell:
vibe work bugfix       # tmux session "vibe-bugfix", separate session UUID cache
```

`vibe work` without a name uses a deterministic-random name derived from the cwd hash, so coming back to the same project always lands on the same session.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first — it's the single entry point for contributors. This project uses a **spec-first workflow**: every feature begins as a design doc in `docs/design/00X-<name>.md` ([template](docs/design/README.md)) reviewed before code is written.

If Claude Code ever shows a rate-limit or modal message we don't match, paste it verbatim into `tests/fixtures/<name>.txt` and open a PR.

## License

MIT.
