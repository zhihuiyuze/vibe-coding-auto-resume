# vibe-coding-auto-resume: shell dispatcher.
# Sourced from ~/.bashrc by install.sh. Defines the `vibe` function as a
# single subcommand entry point. Some subcommands (`work`) must modify the
# caller's shell state and are handled inline; others delegate to scripts.
#
# Environment:
#   VIBE_HOME             — repo root (set by install.sh's marker block)
#   VIBE_PROJECT_ROOT     — working dir for `vibe work` (default: current $PWD
#                           at the moment `vibe work` runs; override in
#                           ~/.config/vibe/env to pin to a fixed project)
#   VIBE_SESSION          — current session name (set inside tmux by `vibe work`)
#   VIBE_STATE_DIR        — per-session state root
#                           (default: ${XDG_STATE_HOME:-~/.local/state}/vibe)

# VIBE_PROJECT_ROOT default is resolved at call time (so it picks up $PWD
# correctly), not at source time.
: "${VIBE_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/vibe}"

# 16 adjectives + 16 nouns = 256 deterministic readable session names.
# Same cwd always maps to the same name (no random surprises across invocations),
# but different projects get visibly different sessions in tmux's session list.
_VIBE_WORDS_ADJ=(red blue calm bold quick wise mild swift dark fair lush keen warm cool brave grey)
_VIBE_WORDS_NOUN=(fox owl ant bee elk yak cow gnu pug ram doe hen jay kit pip orca)

_vibe_default_name() {
  # Deterministic name derived from cwd via cksum. Result like "boldfox".
  local h
  h="$(printf '%s' "$PWD" | cksum | awk '{print $1}')"
  local a=$(( h % 16 ))
  local n=$(( (h / 16) % 16 ))
  printf '%s%s' "${_VIBE_WORDS_ADJ[$a]}" "${_VIBE_WORDS_NOUN[$n]}"
}

# Emit names of vibe-* tmux sessions whose first pane's current_path == $1.
# Uses tmux's pane_current_path (foreground process cwd) — see
# docs/design/011-session-picker.md for the why.
_vibe_sessions_matching_cwd() {
  local target="$1" name cwd
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r name; do
    [[ "$name" == vibe-* ]] || continue
    cwd="$(tmux display-message -p -t "$name" '#{pane_current_path}' 2>/dev/null)"
    [[ "$cwd" == "$target" ]] && printf '%s\n' "$name"
  done
  # Explicit success: the loop's last `[[ ]] && printf` returns 1 on a
  # non-match, which would otherwise bubble out as the function's exit code
  # and trip set -e in strict-mode callers.
  return 0
}

# Print a formatted table of all vibe-* sessions: name, current cwd,
# "← here" if cwd matches $PWD, "[attached]" if a client is connected.
_vibe_ls() {
  if ! tmux list-sessions >/dev/null 2>&1; then
    echo "(no tmux server running)"
    return 0
  fi
  local name attached cwd here tag found=0
  while IFS='|' read -r name attached; do
    [[ "$name" == vibe-* ]] || continue
    found=1
    cwd="$(tmux display-message -p -t "$name" '#{pane_current_path}' 2>/dev/null)"
    here=""; tag=""
    [[ "$cwd" == "$PWD" ]] && here="  ← here"
    (( attached > 0 )) && tag="  [attached]"
    printf '  %-25s  %s%s%s\n' "$name" "$cwd" "$here" "$tag"
  done < <(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null)
  (( found == 0 )) && echo "  (no vibe-* sessions)"
  return 0  # same rationale as _vibe_sessions_matching_cwd
}

# Fall-through "create or attach by cwd-hash" — the original _vibe_work body.
# Factored out so the smart picker can call into it as the "n) new" branch.
_vibe_work_default() {
  local explicit="${1:-}"
  local target="${VIBE_PROJECT_ROOT:-$PWD}"
  cd "$target" || {
    echo "vibe: cannot cd to '$target' (set VIBE_PROJECT_ROOT in ~/.config/vibe/env or run \`vibe work\` from your project)" >&2
    return 1
  }
  local name="${explicit:-$(_vibe_default_name)}"
  local tmux_session="vibe-$name"
  local state_dir="$VIBE_STATE_DIR/$name"
  mkdir -p "$state_dir"

  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    echo "vibe: attaching to existing session '$tmux_session'"
    tmux attach -t "$tmux_session"
  else
    echo "vibe: creating session '$tmux_session' (override with: vibe work <name>)"
    tmux new -As "$tmux_session" -c "$target" \
      -e "VIBE_SESSION=$name" \
      -e "VIBE_STATE_DIR=$VIBE_STATE_DIR"
  fi
}

_vibe_work() {
  local explicit="${1:-}"

  # Explicit name → no discovery, original behavior.
  if [[ -n "$explicit" ]]; then
    _vibe_work_default "$explicit"
    return
  fi

  # No name: discover vibe-* sessions whose cwd matches $PWD.
  local -a matches=()
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] && matches+=("$m")
  done < <(_vibe_sessions_matching_cwd "$PWD")

  case ${#matches[@]} in
    0)
      _vibe_work_default
      ;;
    1)
      echo "vibe: attaching to '${matches[0]}' (only session matching $PWD)"
      tmux attach -t "${matches[0]}"
      ;;
    *)
      if [[ ! -t 0 ]]; then
        echo "vibe: ${#matches[@]} sessions match $PWD (interactive picker requires a TTY):" >&2
        for m in "${matches[@]}"; do echo "  $m" >&2; done
        echo "Re-run with an explicit name: vibe work <name>" >&2
        return 1
      fi
      echo "vibe: ${#matches[@]} sessions match $PWD"
      local i=1
      for m in "${matches[@]}"; do
        printf '  %d) %s\n' "$i" "$m"
        i=$((i+1))
      done
      echo "  n) new session (uses cwd-hash name: $(_vibe_default_name))"
      printf "pick [1-%d/n]: " "${#matches[@]}"
      local choice
      IFS= read -r choice || return 1
      if [[ "$choice" == "n" ]]; then
        _vibe_work_default
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
        local picked="${matches[$((choice-1))]}"
        echo "vibe: attaching to '$picked'"
        tmux attach -t "$picked"
      else
        echo "vibe: invalid choice; aborting." >&2
        return 1
      fi
      ;;
  esac
}

_vibe_help() {
  cat <<EOF
vibe — auto-resume wrapper for agentic coding CLIs

Usage:
  vibe work [name]          enter/attach a vibe tmux session.
                            no name + 0 sessions match \$PWD: create new (cwd-hash name)
                            no name + 1 session  matches \$PWD: attach to it
                            no name + N sessions match \$PWD: interactive picker
                            explicit name: skip discovery, attach/create "vibe-<name>"
  vibe ls                   list all vibe-* tmux sessions (cwd, attached, "← here" if cwd matches)
  vibe history [...flags]   list past Claude Code sessions for \$PWD (UUID, mtime, last user msg)
                            flags: --limit N (default 10; 0 = all), --json, --cwd PATH
  vibe run [...args]        launch underlying agent (claude) with auto-resume
                            vibe flags (override env config, then pass-through):
                              --resume <uuid>        resume a specific session
                              --threshold <0..1>     opt-in soft cap (default off)
                              --max-cycles <n>       resume cycles (0=∞, default 1)
                              --mode auto|session-id|continue
                              --sleep-pad <secs>     buffer after reset (default 60)
                              --provider deepseek|claude|openai|ollama
                              --no-l3                force L1+L2 only
                            other flags pass through to claude unchanged.
  vibe status               print current usage / block end / L3 provider
  vibe setup-workspace      (run from inside a project) create HANDOFF.md + append rules
  vibe teardown-workspace   (run from inside a project) reverse setup-workspace
  vibe install              (re)run installer
  vibe uninstall            remove this tool's installed bits
  vibe help                 this message
  vibe version              print version + tool paths

Multi-session example:
  vibe work feature-x       tmux session vibe-feature-x, isolated session-id state
  vibe work bugfix          tmux session vibe-bugfix, separate state

Global config: \${XDG_CONFIG_HOME:-\$HOME/.config}/vibe/env  (LLM keys live here)
EOF
}

_vibe_version() {
  echo "vibe-coding-auto-resume"
  echo "VIBE_HOME=${VIBE_HOME:-unset}"
  echo "VIBE_PROJECT_ROOT=${VIBE_PROJECT_ROOT:-(unset; \`vibe work\` will use \$PWD)}"
  echo "VIBE_STATE_DIR=$VIBE_STATE_DIR"
  echo "VIBE_SESSION=${VIBE_SESSION:-(not in a vibe tmux session)}"
  command -v vibe-run >/dev/null 2>&1 && echo "vibe-run: $(command -v vibe-run)"
}

vibe() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    work)
      _vibe_work "$@"
      ;;
    ls|list)
      _vibe_ls
      ;;
    run)
      if command -v vibe-run >/dev/null 2>&1; then
        vibe-run "$@"
      elif [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/bin/vibe-run" ]]; then
        "$VIBE_HOME/bin/vibe-run" "$@"
      else
        echo "vibe: vibe-run not found on PATH and VIBE_HOME unset" >&2
        return 127
      fi
      ;;
    status)
      if command -v vibe-status >/dev/null 2>&1; then
        vibe-status "$@"
      elif [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/bin/vibe-status" ]]; then
        "$VIBE_HOME/bin/vibe-status" "$@"
      else
        echo "vibe: vibe-status not found on PATH and VIBE_HOME unset" >&2
        return 127
      fi
      ;;
    history)
      if command -v vibe-history >/dev/null 2>&1; then
        vibe-history "$@"
      elif [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/bin/vibe-history" ]]; then
        "$VIBE_HOME/bin/vibe-history" "$@"
      else
        echo "vibe: vibe-history not found on PATH and VIBE_HOME unset" >&2
        return 127
      fi
      ;;
    install)
      if [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/install.sh" ]]; then
        "$VIBE_HOME/install.sh" "$@"
      else
        echo "vibe: install.sh not found; VIBE_HOME=${VIBE_HOME:-unset}" >&2
        return 127
      fi
      ;;
    uninstall)
      if [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/uninstall.sh" ]]; then
        "$VIBE_HOME/uninstall.sh" "$@"
      else
        echo "vibe: uninstall.sh not found; VIBE_HOME=${VIBE_HOME:-unset}" >&2
        return 127
      fi
      ;;
    session-capture)
      if command -v vibe-session-capture >/dev/null 2>&1; then
        vibe-session-capture "$@"
      elif [[ -n "${VIBE_HOME:-}" && -x "$VIBE_HOME/bin/vibe-session-capture" ]]; then
        "$VIBE_HOME/bin/vibe-session-capture" "$@"
      else
        echo "vibe: vibe-session-capture not found" >&2
        return 127
      fi
      ;;
    setup-workspace)
      if [[ -z "${VIBE_HOME:-}" || ! -f "$VIBE_HOME/lib/setup-workspace.sh" ]]; then
        echo "vibe: setup-workspace script not found; VIBE_HOME=${VIBE_HOME:-unset}" >&2
        return 127
      fi
      bash "$VIBE_HOME/lib/setup-workspace.sh" "$@"
      ;;
    teardown-workspace)
      if [[ -z "${VIBE_HOME:-}" || ! -f "$VIBE_HOME/lib/teardown-workspace.sh" ]]; then
        echo "vibe: teardown-workspace script not found; VIBE_HOME=${VIBE_HOME:-unset}" >&2
        return 127
      fi
      bash "$VIBE_HOME/lib/teardown-workspace.sh" "$@"
      ;;
    version|--version|-v)
      _vibe_version
      ;;
    help|--help|-h|"")
      _vibe_help
      ;;
    *)
      echo "vibe: unknown subcommand '$cmd'. Try 'vibe help'." >&2
      return 2
      ;;
  esac
}
