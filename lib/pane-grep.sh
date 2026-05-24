# L2 — pane keyword grep. See docs/design/001-three-layer-detection.md.
#
# Sourced. Exposes:
#   capture_tail            — last N lines of the claude tmux pane
#   pane_grep <group>       — return 0 if pattern for <group> matches, 1 otherwise
#   extract_reset_time      — best-effort ISO 8601 extraction from limit message
#   _get_pattern <group>    — internal lookup from config/grep-patterns.txt

# Larger default than initial v1 (30) — subagent rate-limit messages can scroll
# off the visible viewport before claude exits. We capture from scrollback too.
: "${CC_PANE_TAIL_LINES:=200}"
: "${CC_PANE_SCROLLBACK:=2000}"
: "${CC_TMUX_TARGET:=claude}"

_CC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CC_GREP_PATTERNS:=$_CC_LIB_DIR/../config/grep-patterns.txt}"

_get_pattern() {
  local group="$1"
  # First non-comment, non-blank line that starts with "<group>:"
  grep -E "^${group}:" "$CC_GREP_PATTERNS" 2>/dev/null \
    | head -1 \
    | sed -E "s/^${group}://"
}

capture_tail() {
  local target="${1:-$CC_TMUX_TARGET}"
  # -p: print to stdout; -t: target; -S -<N>: start N lines back in scrollback.
  # We then tail CC_PANE_TAIL_LINES from that buffer so subagent messages that
  # scrolled off-screen are still detectable.
  # Fall back to stdin if not in tmux (lets us pipe fixtures in for tests).
  if [[ -n "${TMUX:-}" ]] && tmux has-session -t "$target" 2>/dev/null; then
    tmux capture-pane -p -t "$target" -S "-$CC_PANE_SCROLLBACK" 2>/dev/null \
      | tail -n "$CC_PANE_TAIL_LINES"
  else
    cat
  fi
}

pane_grep() {
  local group="$1" text="${2:-}" pattern
  pattern="$(_get_pattern "$group")"
  [[ -z "$pattern" ]] && return 2  # unknown group
  if [[ -n "$text" ]]; then
    grep -qiE "$pattern" <<<"$text"
  else
    capture_tail | grep -qiE "$pattern"
  fi
}

# Best-effort: extract a reset clock-time and emit ISO 8601 (UTC) assuming local TZ.
# Formats handled:
#   "resets 12pm"
#   "resets 12:30pm"
#   "resets Oct 31, 9am"
#   "resets 3pm (America/Santiago)"
# Returns empty string on no match.
extract_reset_time() {
  local text="${1:-$(capture_tail)}" pattern raw tz iso
  pattern="$(_get_pattern reset)"
  raw="$(grep -oiE "$pattern" <<<"$text" | head -1)"
  [[ -z "$raw" ]] && return 0

  # Strip leading "resets " / "reset " / "reset at "
  raw="${raw#[Rr]esets }"
  raw="${raw#[Rr]esets}"
  raw="${raw#[Rr]eset at }"
  raw="${raw#[Rr]eset }"
  raw="${raw# }"
  # `date -d` rejects "Oct 31, 9am" (comma); accepts "Oct 31 9am". Drop commas.
  raw="${raw//,/}"

  # Extract TZ if "(Area/City)" present
  tz=""
  if [[ "$raw" =~ \(([^\)]+)\) ]]; then
    tz="${BASH_REMATCH[1]}"
    raw="${raw% (*}"
  fi

  # date -d understands most of these directly. Try local TZ first, then override if tz known.
  if [[ -n "$tz" ]]; then
    iso="$(TZ="$tz" date -d "$raw" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || iso=""
  else
    iso="$(date -d "$raw" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || iso=""
  fi
  echo "$iso"
}

# Standalone debug mode: `bash lib/pane-grep.sh limit < fixture.txt`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  group="${1:?usage: pane-grep.sh <group> [<text>]}"
  text="$(cat)"
  if pane_grep "$group" "$text"; then
    echo "match"
    [[ "$group" == "limit" || "$group" == "weekly_limit" || "$group" == "api_error" ]] && \
      echo "reset_time: $(extract_reset_time "$text")"
    exit 0
  else
    echo "no match"
    exit 1
  fi
fi
