# tmux pane helpers — capture, idle detect, post-resume compaction handler.
# See docs/design/008-post-resume-compaction.md.
#
# Sourced. Exposes:
#   detect_idle             — pane is at the input prompt with no recent activity
#   handle_post_resume <pid> — background: detect compaction prompt, print warning
#                             or (Phase 2, when fixtures land) auto-answer

: "${CC_TMUX_TARGET:=claude}"
: "${CC_POST_RESUME_WAIT:=15}"      # seconds to watch for compaction prompt
: "${CC_POST_RESUME_SETTLE:=2}"     # seconds before first poll
: "${CC_COMPACTION_CHOICE:=keep}"

_CC_LIB_DIR_TP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ensure pane-grep helpers are available even when sourced standalone.
if ! declare -f pane_grep >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_CC_LIB_DIR_TP/pane-grep.sh"
fi

# Heuristic: pane is idle if the last visible line matches the "idle" group
# (prompt cursor) AND the tail hasn't changed between two captures 1s apart.
detect_idle() {
  local target="${1:-$CC_TMUX_TARGET}" snap1 snap2
  snap1="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -3)"
  sleep 1
  snap2="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -3)"
  [[ "$snap1" == "$snap2" ]] || return 1
  pane_grep idle "$snap2"
}

# Phase 1: detect-and-warn only. Once tests/fixtures/compaction-prompt-*.txt
# contains real samples, Phase 2 reads CC_COMPACTION_CHOICE and sends keys.
handle_post_resume() {
  local pid="${1:-}"  # informational; we don't kill it
  sleep "$CC_POST_RESUME_SETTLE"
  local elapsed=0 max="$CC_POST_RESUME_WAIT"
  while (( elapsed < max )); do
    # If the resumed Claude already exited, nothing for us to do.
    [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 0

    if pane_grep compaction; then
      cat <<MSG >&2
[post-resume] Compaction prompt detected in the Claude pane.
[post-resume] Verbatim wording is not yet known for this Claude Code version,
[post-resume] so I cannot answer it automatically. Please respond manually in
[post-resume] the tmux window. To help future runs, capture the prompt with:
[post-resume]   tmux capture-pane -p -t $CC_TMUX_TARGET | tail -30 > \\
[post-resume]     tests/fixtures/compaction-prompt-\$(date +%s).txt
[post-resume] and open a PR.
MSG
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  # No compaction prompt within the window — most common case.
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    idle) detect_idle ;;
    post-resume) handle_post_resume "${2:-}" ;;
    *) echo "usage: tmux-pane.sh {idle|post-resume [<pid>]}" >&2; exit 2 ;;
  esac
fi
