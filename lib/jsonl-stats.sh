# L1 — JSONL stats. See docs/design/002-jsonl-parsing.md.
#
# Sourced (not executed). Exposes:
#   encoded_cwd            — pwd with / replaced by -
#   current_session_jsonl  — newest *.jsonl in this project's encoded dir
#   block_tokens           — sum of message.usage tokens for current session
#   block_start_iso        — first message timestamp in current session
#   block_end_iso          — block_start + 5h
#   historical_peak        — max block_tokens across all *.jsonl files
#   jsonl_stats            — composite JSON {block_pct, block_end_iso, peak}

: "${CC_PEAK_FALLBACK:=200000}"
: "${CLAUDE_PROJECTS_DIR:=$HOME/.claude/projects}"

encoded_cwd() {
  pwd | sed 's|/|-|g'
}

current_session_jsonl() {
  local dir="$CLAUDE_PROJECTS_DIR/$(encoded_cwd)"
  [[ -d "$dir" ]] || return 1
  # newest by mtime, suppress "no match" warning when empty
  ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

# Sum input + output + cache_read_input tokens across all turns in a JSONL file.
# Missing fields default to 0. cache_creation is intentionally excluded per
# Anthropic's rate-limit accounting.
block_tokens() {
  local jsonl="${1:-$(current_session_jsonl)}"
  [[ -n "$jsonl" && -f "$jsonl" ]] || { echo 0; return; }
  jq -s '
    [.[]
     | (.message.usage // empty)
     | ((.input_tokens // 0) + (.output_tokens // 0) + (.cache_read_input_tokens // 0))
    ] | add // 0
  ' "$jsonl" 2>/dev/null || echo 0
}

block_start_iso() {
  local jsonl="${1:-$(current_session_jsonl)}"
  [[ -n "$jsonl" && -f "$jsonl" ]] || { echo ""; return; }
  # Not every JSONL row carries .timestamp (e.g. agentName/aiTitle rows skip it).
  # Filter to rows that have it before taking the first.
  jq -s '[.[] | select(.timestamp)] | (first.timestamp // empty)' "$jsonl" 2>/dev/null | tr -d '"'
}

block_end_iso() {
  local start
  start="$(block_start_iso "${1:-}")"
  [[ -z "$start" ]] && { echo ""; return; }
  # 5 hours in seconds = 18000
  local start_epoch
  start_epoch="$(date -d "$start" +%s 2>/dev/null)" || { echo ""; return; }
  date -u -d "@$((start_epoch + 18000))" +%Y-%m-%dT%H:%M:%SZ
}

# Max block_tokens across all sibling project dirs (your usage envelope).
historical_peak() {
  local max=0 tokens jsonl
  shopt -s nullglob
  for jsonl in "$CLAUDE_PROJECTS_DIR"/*/*.jsonl; do
    tokens="$(block_tokens "$jsonl")"
    (( tokens > max )) && max=$tokens
  done
  shopt -u nullglob
  (( max == 0 )) && max=$CC_PEAK_FALLBACK
  echo "$max"
}

# Composite JSON. Wrapper consumes this with jq.
jsonl_stats() {
  local current peak tokens pct end
  current="$(current_session_jsonl)" || current=""
  peak="$(historical_peak)"
  tokens="$(block_tokens "$current")"
  end="$(block_end_iso "$current")"
  if [[ "$peak" -gt 0 ]]; then
    # bash float math via awk; clamp to [0, 1].
    pct="$(awk -v t="$tokens" -v p="$peak" 'BEGIN{ x=t/p; if(x<0)x=0; if(x>1)x=1; printf "%.4f", x }')"
  else
    pct="0.0000"
  fi
  jq -nc \
    --argjson block_pct "$pct" \
    --arg block_end_iso "${end:-}" \
    --argjson peak "$peak" \
    --argjson block_tokens "$tokens" \
    '{block_pct: $block_pct, block_end_iso: $block_end_iso, peak: $peak, block_tokens: $block_tokens}'
}

# Return the raw tail of the current session's JSONL. Used as a fallback text
# source when L2 pane-grep misses content (e.g., subagent rate-limit messages
# that lived in a tab Claude wasn't actively rendering at exit time).
# Raw jsonl is JSON-encoded text; our grep patterns don't care about escaping,
# so direct grep against tail works.
jsonl_recent_text() {
  local n="${1:-300}"
  local jsonl
  jsonl="$(current_session_jsonl)" || return 1
  [[ -z "$jsonl" || ! -f "$jsonl" ]] && return 1
  tail -n "$n" "$jsonl"
}

# If sourced, do nothing. If executed (handy for debugging), print stats.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-stats}" in
    stats) jsonl_stats ;;
    text)  jsonl_recent_text "${2:-300}" ;;
    *) echo "usage: jsonl-stats.sh {stats|text [N]}" >&2; exit 2 ;;
  esac
fi
