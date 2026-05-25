#!/usr/bin/env bash
# vibe-coding-auto-resume — smoke tests.
#
# Layered: L1 jsonl-stats, L2 pane-grep, L3 llm-classify (mocked), plus an
# end-to-end pass over bin/vibe-run with a stub `claude` binary.
#
# No real API calls. Set CC_SMOKE_REAL_API=1 to opt into provider smoke tests
# (skipped by default; not implemented in this script — placeholder gate only).
#
# Run from any cwd:
#   bash tests/smoke.sh

set -euo pipefail

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_DIR="$(cd "$_TEST_DIR/.." && pwd)"
_LIB_DIR="$_REPO_DIR/lib"
_BIN_DIR="$_REPO_DIR/bin"
_CFG_DIR="$_REPO_DIR/config"
_FIXTURES="$_TEST_DIR/fixtures"

# Sandbox: scratch HOME-like area so we don't touch the real ~/.claude.
_TMP_ROOT="$(mktemp -d -t cc-smoke-XXXXXX)"
_TMP_PROJECTS="$_TMP_ROOT/projects"
_TMP_BIN="$_TMP_ROOT/fake-bin"
_TMP_SESSION_FILE="$_TMP_ROOT/session"
mkdir -p "$_TMP_PROJECTS" "$_TMP_BIN"

cleanup() {
  rm -rf "$_TMP_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }
section() { printf '\n--- %s ---\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then pass "$msg"
  else fail "$msg (got=$got want=$want)"; fi
}

assert_nonempty() {
  local got="$1" msg="$2"
  if [[ -n "$got" ]]; then pass "$msg"
  else fail "$msg (got empty)"; fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$msg"
  else fail "$msg (needle '$needle' not in: $hay)"; fi
}

assert_not_contains() {
  local hay="$1" needle="$2" msg="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$msg"
  else fail "$msg (needle '$needle' unexpectedly present)"; fi
}

###############################################################################
section "L1 — jsonl-stats.sh"
###############################################################################

# Build a synthetic project dir mirroring ~/.claude/projects/<encoded_cwd>/
# Use an arbitrary encoded path; jsonl_stats() reads from
# CLAUDE_PROJECTS_DIR/$(encoded_cwd). We override encoded_cwd via cwd.
_FAKE_WORKDIR="$_TMP_ROOT/work/proj"
mkdir -p "$_FAKE_WORKDIR"
# encoded_cwd replaces / with -; the path becomes -tmp-...-work-proj
_ENC="$(echo "$_FAKE_WORKDIR" | sed 's|/|-|g')"
_PROJ_DIR="$_TMP_PROJECTS/$_ENC"
mkdir -p "$_PROJ_DIR"

# Two synthetic JSONL turns with known token counts:
#   turn1: 100 input + 200 output + 50 cache_read = 350
#   turn2: 400 input + 600 output + 100 cache_read = 1100
#   total = 1450 (cache_creation excluded by design)
_UUID="11111111-2222-3333-4444-555555555555"
_JSONL="$_PROJ_DIR/$_UUID.jsonl"
cat > "$_JSONL" <<'JSONL'
{"timestamp":"2026-05-24T08:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":50,"cache_creation_input_tokens":9999}}}
{"timestamp":"2026-05-24T08:05:00Z","message":{"usage":{"input_tokens":400,"output_tokens":600,"cache_read_input_tokens":100,"cache_creation_input_tokens":1234}}}
JSONL

# Source the lib in a subshell-isolating fashion by cd'ing into the fake work dir.
# jsonl-stats sources fine under set -u.
(
  set +u
  cd "$_FAKE_WORKDIR"
  export CLAUDE_PROJECTS_DIR="$_TMP_PROJECTS"
  export CC_PEAK_FALLBACK=200000
  # shellcheck disable=SC1090
  source "$_LIB_DIR/jsonl-stats.sh"
  set -u

  got_tokens="$(block_tokens)"
  echo "__BT__ $got_tokens"

  got_json="$(jsonl_stats)"
  echo "__JS__ $got_json"
) > "$_TMP_ROOT/l1.out"

bt_line="$(grep '^__BT__' "$_TMP_ROOT/l1.out" | head -1 | sed 's/^__BT__ //')"
assert_eq "$bt_line" "1450" "block_tokens sums input+output+cache_read across turns"

js_line="$(grep '^__JS__' "$_TMP_ROOT/l1.out" | head -1 | sed 's/^__JS__ //')"
if echo "$js_line" | jq -e . >/dev/null 2>&1; then
  pass "jsonl_stats emits valid JSON"
else
  fail "jsonl_stats emits valid JSON (got: $js_line)"
fi

# Sensible fields: required keys exist and have plausible types/values.
js_bt="$(echo "$js_line" | jq -r '.block_tokens')"
assert_eq "$js_bt" "1450" "jsonl_stats.block_tokens == 1450"

js_end="$(echo "$js_line" | jq -r '.block_end_iso')"
assert_eq "$js_end" "2026-05-24T13:00:00Z" "jsonl_stats.block_end_iso == start+5h"

js_peak="$(echo "$js_line" | jq -r '.peak')"
if [[ "$js_peak" =~ ^[0-9]+$ ]] && (( js_peak >= 1450 )); then
  pass "jsonl_stats.peak is integer >= block_tokens"
else
  fail "jsonl_stats.peak is integer >= block_tokens (got=$js_peak)"
fi

js_pct="$(echo "$js_line" | jq -r '.block_pct')"
# pct should be a finite number in [0,1]
if awk -v p="$js_pct" 'BEGIN{exit !(p+0==p && p>=0 && p<=1)}' 2>/dev/null; then
  pass "jsonl_stats.block_pct in [0,1]"
else
  fail "jsonl_stats.block_pct in [0,1] (got=$js_pct)"
fi

###############################################################################
section "L2 — pane-grep.sh: per-fixture classification"
###############################################################################

# Sourcing pane-grep.sh requires its CC_GREP_PATTERNS default to resolve.
# It auto-resolves via _CC_LIB_DIR = dirname of the script.
(
  set +u
  # shellcheck disable=SC1090
  source "$_LIB_DIR/pane-grep.sh"
  set -u

  # Each fixture: (file, expected match groups, expected non-match groups).
  declare -a CASES=(
    "5h-limit-1.txt|limit|warning approaching weekly_limit limit_modal"
    "weekly-opus-1.txt|weekly_limit|warning limit_modal"
    "approaching-1.txt|warning|limit weekly_limit limit_modal"
    "api-error-tz.txt|api_error|warning limit_modal"
    "limit-modal-3option-1.txt|limit_modal|limit weekly_limit warning api_error"
    "normal-exit.txt||limit weekly_limit warning api_error limit_modal"
    "real-error.txt||limit weekly_limit warning api_error limit_modal"
  )

  for case in "${CASES[@]}"; do
    IFS='|' read -r file should_match should_not_match <<<"$case"
    text="$(cat "$_FIXTURES/$file")"
    if [[ -n "$should_match" ]]; then
      for g in $should_match; do
        if pane_grep "$g" "$text"; then
          echo "P|fixture $file matches group '$g'"
        else
          echo "F|fixture $file should match group '$g'"
        fi
      done
    fi
    for g in $should_not_match; do
      if pane_grep "$g" "$text"; then
        echo "F|fixture $file should NOT match group '$g'"
      else
        echo "P|fixture $file does not match group '$g'"
      fi
    done
  done
) > "$_TMP_ROOT/l2.out"

while IFS='|' read -r tag msg; do
  case "$tag" in
    P) pass "$msg" ;;
    F) fail "$msg" ;;
  esac
done < "$_TMP_ROOT/l2.out"

###############################################################################
section "L2 — extract_reset_time on limit fixtures"
###############################################################################

(
  set +u
  # shellcheck disable=SC1090
  source "$_LIB_DIR/pane-grep.sh"
  set -u
  for f in 5h-limit-1.txt weekly-opus-1.txt api-error-tz.txt; do
    iso="$(extract_reset_time "$(cat "$_FIXTURES/$f")")"
    echo "RESET|$f|$iso"
  done
) > "$_TMP_ROOT/reset.out"

while IFS='|' read -r _ file iso; do
  if [[ -n "$iso" ]]; then
    # Loose ISO 8601 shape check: YYYY-MM-DDTHH:MM:SSZ
    if [[ "$iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      pass "extract_reset_time($file) returns ISO 8601 ($iso)"
    else
      fail "extract_reset_time($file) shape (got=$iso)"
    fi
  else
    fail "extract_reset_time($file) returned empty"
  fi
done < "$_TMP_ROOT/reset.out"

###############################################################################
section "L2.5 — JSONL text scan catches subagent rate-limit message"
###############################################################################

# Stage a synthetic project dir with a JSONL whose subagent block carries the
# rate-limit text. Verify jsonl_recent_text returns it AND pane_grep matches.
_TMP_PROJ_NAME="-$(pwd | sed 's|/|-|g' | tr -d '-')-jsonl-scan-test"
_TMP_PROJ_DIR="$_TMP_PROJECTS/$_TMP_PROJ_NAME"
mkdir -p "$_TMP_PROJ_DIR"
cp "$_FIXTURES/jsonl-with-limit.jsonl" "$_TMP_PROJ_DIR/test-session.jsonl"

(
  set +u
  # shellcheck disable=SC1090
  CLAUDE_PROJECTS_DIR="$_TMP_PROJECTS"
  cd "$_TMP_ROOT"   # cd to something whose encoded form != real claude dirs
  # Force the encoded-cwd resolver to find our fixture by faking it via pwd
  # Strategy: use the actual fixture file path directly via jsonl_recent_text's caller.
  # Easiest: source jsonl-stats and override current_session_jsonl.
  source "$_LIB_DIR/jsonl-stats.sh"
  current_session_jsonl() { echo "$_TMP_PROJ_DIR/test-session.jsonl"; }
  text="$(jsonl_recent_text 100)"
  set -u
  if [[ -z "$text" ]]; then
    echo "L25|FAIL|jsonl_recent_text returned empty"
  else
    source "$_LIB_DIR/pane-grep.sh"
    if pane_grep limit "$text"; then
      iso="$(extract_reset_time "$text")"
      echo "L25|PASS|jsonl scan matched 'limit'; reset_time='$iso'"
    else
      echo "L25|FAIL|jsonl scan didn't match (text head: $(echo "$text" | head -c 80))"
    fi
  fi
) > "$_TMP_ROOT/l25.out"

while IFS='|' read -r _ tag msg; do
  case "$tag" in
    PASS) pass "$msg" ;;
    FAIL) fail "$msg" ;;
  esac
done < "$_TMP_ROOT/l25.out"

###############################################################################
section "L3 — llm-classify.sh: detect_provider"
###############################################################################

run_detect() {
  # Run detect_provider in an isolated bash subshell with controlled env.
  env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '
    set -uo pipefail
    source "'"$_LIB_DIR"'/llm-classify.sh"
    detect_provider
  '
}

got="$(run_detect)"
assert_eq "${got:-<empty>}" "<empty>" "detect_provider with no vars set returns empty"

got="$(run_detect DEEPSEEK_API_KEY=sk-ds)"
assert_eq "$got" "deepseek" "detect_provider picks deepseek from DEEPSEEK_API_KEY"

got="$(run_detect ANTHROPIC_API_KEY=sk-an)"
assert_eq "$got" "claude" "detect_provider picks claude from ANTHROPIC_API_KEY"

got="$(run_detect OPENAI_API_KEY=sk-oa)"
assert_eq "$got" "openai" "detect_provider picks openai from OPENAI_API_KEY"

got="$(run_detect OLLAMA_HOST=http://localhost:11434)"
assert_eq "$got" "ollama" "detect_provider picks ollama from OLLAMA_HOST"

# Priority: deepseek > claude > openai > ollama
got="$(run_detect DEEPSEEK_API_KEY=sk-ds ANTHROPIC_API_KEY=sk-an OPENAI_API_KEY=sk-oa OLLAMA_HOST=x)"
assert_eq "$got" "deepseek" "detect_provider priority: deepseek wins"

# Explicit override
got="$(run_detect CC_LLM_PROVIDER=openai DEEPSEEK_API_KEY=sk-ds)"
assert_eq "$got" "openai" "detect_provider: CC_LLM_PROVIDER overrides keys"

got="$(run_detect CC_LLM_PROVIDER=none DEEPSEEK_API_KEY=sk-ds)"
assert_eq "$got" "none" "detect_provider: CC_LLM_PROVIDER=none returned literally"

###############################################################################
section "L3 — redact"
###############################################################################

(
  set +u
  # shellcheck disable=SC1090
  source "$_LIB_DIR/llm-classify.sh"
  set -u
  out="$(redact 'auth sk-abcdef0123456789ABCDEF more text')"
  echo "R1|$out"
  out="$(redact 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')"
  echo "R2|$out"
  out="$(redact 'export APP_SECRET=hunter2 done')"
  echo "R3|$out"
  out="$(redact 'token=ZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVm rest')"
  echo "R4|$out"
) > "$_TMP_ROOT/redact.out"

r1="$(grep '^R1|' "$_TMP_ROOT/redact.out" | sed 's/^R1|//')"
assert_contains "$r1" "sk-REDACTED" "redact masks sk-* API keys"
assert_not_contains "$r1" "abcdef0123456789" "redact removes raw sk-* contents"

r2="$(grep '^R2|' "$_TMP_ROOT/redact.out" | sed 's/^R2|//')"
assert_contains "$r2" "Bearer REDACTED" "redact masks Bearer tokens"
assert_not_contains "$r2" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "redact removes raw Bearer payload"

r3="$(grep '^R3|' "$_TMP_ROOT/redact.out" | sed 's/^R3|//')"
assert_contains "$r3" "APP_SECRET=REDACTED" "redact masks *_SECRET= assignments"
assert_not_contains "$r3" "hunter2" "redact removes raw secret value"

r4="$(grep '^R4|' "$_TMP_ROOT/redact.out" | sed 's/^R4|//')"
assert_contains "$r4" "BASE64_REDACTED" "redact masks long base64-looking strings"

###############################################################################
section "L3 — llm_classify with mocked curl"
###############################################################################

# Inject a fake curl on PATH that emits a canned response + HTTP code.
# The lib appends `\n%{http_code}` via `-w`, so our shim must print
# "<body>\n200" to satisfy code/body splitting.
cat > "$_TMP_BIN/curl" <<'SHIM'
#!/usr/bin/env bash
# Canned LLM response for smoke tests. Shape matches OpenAI/DeepSeek schema.
read -r -d '' BODY <<'JSON' || true
{"choices":[{"message":{"content":"{\"status\":\"limit_hit\",\"reset_time\":\"2026-05-24T18:30:00Z\",\"idle\":false,\"modal_open\":false,\"reasoning\":\"5-hour limit message detected\"}"}}]}
JSON
printf '%s\n200\n' "$BODY"
SHIM
chmod +x "$_TMP_BIN/curl"

(
  set +u
  export PATH="$_TMP_BIN:$PATH"
  export DEEPSEEK_API_KEY="sk-fake-for-mock"
  unset CC_LLM_PROVIDER
  # shellcheck disable=SC1090
  source "$_LIB_DIR/llm-classify.sh"
  set -u
  out="$(llm_classify "$(cat "$_FIXTURES/5h-limit-1.txt")")"
  echo "CL|$out"
) > "$_TMP_ROOT/classify.out" 2>&1 || true

cl_line="$(grep '^CL|' "$_TMP_ROOT/classify.out" | head -1 | sed 's/^CL|//')"
if echo "$cl_line" | jq -e . >/dev/null 2>&1; then
  pass "llm_classify (mock curl) returns valid JSON"
  cl_status="$(echo "$cl_line" | jq -r '.status')"
  assert_eq "$cl_status" "limit_hit" "llm_classify status passes through from mocked response"
  cl_reset="$(echo "$cl_line" | jq -r '.reset_time')"
  assert_eq "$cl_reset" "2026-05-24T18:30:00Z" "llm_classify reset_time passes through"
else
  fail "llm_classify (mock curl) returns valid JSON (got: $cl_line)"
fi

###############################################################################
section "L3 degraded mode: no provider configured"
###############################################################################

(
  set +u
  env -i HOME="$HOME" PATH="$PATH" CC_LLM_PROVIDER='' bash -c '
    set -uo pipefail
    source "'"$_LIB_DIR"'/llm-classify.sh"
    p="$(detect_provider)"
    printf "DP|%s\n" "${p:-<empty>}"
    out="$(llm_classify "irrelevant pane text" || true)"
    printf "LC|%s\n" "$out"
  '
) > "$_TMP_ROOT/degraded.out"

dp="$(grep '^DP|' "$_TMP_ROOT/degraded.out" | head -1 | sed 's/^DP|//')"
assert_eq "$dp" "<empty>" "degraded mode: detect_provider returns empty"

lc="$(grep '^LC|' "$_TMP_ROOT/degraded.out" | head -1 | sed 's/^LC|//')"
if echo "$lc" | jq -e . >/dev/null 2>&1; then
  pass "degraded mode: llm_classify emits valid JSON"
  lc_status="$(echo "$lc" | jq -r '.status')"
  assert_eq "$lc_status" "error" "degraded mode: llm_classify status=error"
else
  fail "degraded mode: llm_classify emits valid JSON (got: $lc)"
fi

###############################################################################
section "End-to-end — bin/vibe-run with stubbed claude"
###############################################################################

if [[ ! -x "$_BIN_DIR/vibe-run" ]]; then
  skip "bin/vibe-run does not exist yet — E2E gated until wrapper lands"
else
  # Stub `claude` that records args + can simulate different exit scenarios
  # based on a control env var.
  cat > "$_TMP_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Smoke-test stub for `claude`. Reads CC_STUB_MODE to choose behavior.
echo "[stub-claude] args: $*" >&2
mode="${CC_STUB_MODE:-clean}"
case "$mode" in
  clean)       echo "task complete"; echo "> /exit"; exit 0 ;;
  rate-limit)  echo "5-hour limit reached \xe2\x88\x99 resets 12pm"; exit 0 ;;
  crash)       echo "Error: ECONNREFUSED" >&2; exit 137 ;;
  *)           echo "unknown stub mode: $mode" >&2; exit 2 ;;
esac
STUB
  chmod +x "$_TMP_BIN/claude"

  run_wrapper() {
    local mode="$1"
    # Wrapper requires tmux env; many wrappers check $TMUX. We pass it through
    # but also set a safe default so the wrapper believes it's inside tmux.
    env -i HOME="$HOME" \
      PATH="$_TMP_BIN:$PATH" \
      TMUX="${TMUX:-/tmp/fake-tmux,0,0}" \
      CC_STUB_MODE="$mode" \
      CC_LLM_PROVIDER=none \
      CC_RESUME_MAX_CYCLES=0 \
      CC_SESSION_FILE="$_TMP_SESSION_FILE" \
      CC_SLEEP_PAD=0 \
      CLAUDE_PROJECTS_DIR="$_TMP_PROJECTS" \
      bash "$_BIN_DIR/vibe-run" 2>&1
  }

  out="$(run_wrapper clean || true)"
  assert_contains "$out" "[stub-claude]" "E2E: wrapper exec'd stubbed claude (clean)"

  out="$(run_wrapper crash || true)"
  assert_not_contains "$out" "Sleeping" "E2E: crash output does not trigger resume sleep"

  # Rate-limit branch: wrapper should detect limit keywords. We only check
  # that the wrapper saw and acted on them (printed something about limit).
  out="$(run_wrapper rate-limit || true)"
  if echo "$out" | grep -qiE 'limit|resume|sleep'; then
    pass "E2E: wrapper recognizes rate-limit signal from stub"
  else
    fail "E2E: wrapper recognizes rate-limit signal from stub (out: $(echo "$out" | tail -5))"
  fi
fi

###############################################################################
section "bin/vibe-history — table + --json + --limit + empty cwd"
###############################################################################

# Stage a synthetic ~/.claude/projects/<encoded>/ with two JSONLs carrying
# distinct user messages and different mtimes.
_VH_TARGET_CWD="/tmp/fake-vh-project"
_VH_ENCODED="$(printf '%s' "$_VH_TARGET_CWD" | sed 's|/|-|g')"
_VH_PROJ="$_TMP_ROOT/projects-vh/$_VH_ENCODED"
mkdir -p "$_VH_PROJ"

# Older session
cat > "$_VH_PROJ/older-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl" <<'JSONL'
{"timestamp":"2026-05-22T10:00:00Z","message":{"role":"user","content":"refactor the L3 provider abstraction"}}
{"timestamp":"2026-05-22T10:00:30Z","message":{"role":"assistant","content":"OK, let me look at it."}}
JSONL
# Make it older by touch.
touch -d "2026-05-22 10:00:00" "$_VH_PROJ/older-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"

# Newer session with array-style content + a compact-summary that should be SKIPPED
# + a real user message that should win.
cat > "$_VH_PROJ/newer-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl" <<'JSONL'
{"timestamp":"2026-05-25T12:33:00Z","message":{"role":"user","content":"This session is being continued from a previous conversation..."},"isCompactSummary":true}
{"timestamp":"2026-05-25T12:34:00Z","message":{"role":"user","content":[{"type":"text","text":"fix the modal handler when claude exits"}]}}
{"timestamp":"2026-05-25T12:34:10Z","message":{"role":"assistant","content":"On it."}}
{"timestamp":"2026-05-25T12:34:20Z","message":{"role":"user","content":[{"type":"text","text":"actually do something else first"}]}}
JSONL
touch -d "2026-05-25 12:34:00" "$_VH_PROJ/newer-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl"

# Unicode + truncation regression: a 3rd session whose last user msg is long
# Chinese text. Verifies char-aware truncation (no mid-byte cut) + valid JSON
# round-trip through --arg.
cat > "$_VH_PROJ/unicode-cccc-cccc-cccc-cccccccccccc.jsonl" <<'JSONL'
{"timestamp":"2026-05-20T08:00:00Z","message":{"role":"user","content":"修复模态框处理器当claude退出时的问题，并增加单元测试覆盖率到百分之九十以上，确保所有边缘情况都被覆盖到位"}}
JSONL
touch -d "2026-05-20 08:00:00" "$_VH_PROJ/unicode-cccc-cccc-cccc-cccccccccccc.jsonl"

run_vh() {
  CLAUDE_PROJECTS_DIR="$_TMP_ROOT/projects-vh" "$_BIN_DIR/vibe-history" --cwd "$_VH_TARGET_CWD" "$@"
}

# Table mode: 3 rows (older + newer + unicode), newer first
out="$(run_vh)"
line_count="$(echo "$out" | wc -l)"
assert_eq "$line_count" "3" "vibe-history table: 3 rows for 3 staged sessions"

first_line="$(echo "$out" | head -1)"
assert_contains "$first_line" "newer-bbbb-bbbb-bbbb-bbbbbbbbbbbb" "vibe-history table: newer session first (mtime-desc)"
assert_contains "$first_line" "actually do something else first" "vibe-history table: last user msg of newer is captured"

assert_not_contains "$first_line" "This session is being continued" "vibe-history: isCompactSummary row is skipped"

# Unicode row: Chinese content survives, no mojibake
unicode_line="$(echo "$out" | grep 'unicode-cccc')"
assert_contains "$unicode_line" "修复模态框" "vibe-history table: unicode content preserved"

# --limit 1
out="$(run_vh --limit 1)"
line_count="$(echo "$out" | wc -l)"
assert_eq "$line_count" "1" "vibe-history --limit 1: caps to 1 row"

# --json: valid JSON array of length 3 (this is the regression that mid-byte
# truncation used to break)
out="$(run_vh --json)"
if echo "$out" | jq -e 'type == "array" and length == 3' >/dev/null 2>&1; then
  pass "vibe-history --json: valid JSON array of length 3 (incl. unicode row)"
else
  fail "vibe-history --json: expected JSON array of length 3 (got: $(echo "$out" | head -c 200))"
fi

# JSON object shape
first_uuid="$(echo "$out" | jq -r '.[0].uuid')"
assert_eq "$first_uuid" "newer-bbbb-bbbb-bbbb-bbbbbbbbbbbb" "vibe-history --json: [0].uuid is newer session"

first_msgs="$(echo "$out" | jq -r '.[0].msgs')"
assert_eq "$first_msgs" "4" "vibe-history --json: newer session msgs == 4 (incl. compact-summary line)"

# Unicode round-trip through JSON
uni_msg="$(echo "$out" | jq -r '.[] | select(.uuid | startswith("unicode-")) | .last_user_message')"
assert_contains "$uni_msg" "修复模态框" "vibe-history --json: unicode last_user_message round-trips"

# Empty cwd (no projects/ subdir for it) → friendly message + exit 0
out="$(run_vh --cwd /nonexistent/path 2>&1 || true)"
assert_contains "$out" "no Claude Code sessions found" "vibe-history --cwd /nonexistent: empty-set message"

# --help exits 0 with usage text
help_out="$("$_BIN_DIR/vibe-history" --help 2>&1)"
assert_contains "$help_out" "--limit" "vibe-history --help: usage mentions --limit"
assert_contains "$help_out" "--json"  "vibe-history --help: usage mentions --json"

# Unknown flag exits 2
set +e
"$_BIN_DIR/vibe-history" --bogus >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "2" "vibe-history --bogus: rc=2"

###############################################################################
section "shell/vibe.bash — _vibe_sessions_matching_cwd (stubbed tmux)"
###############################################################################

# Shim a fake `tmux` on PATH that returns canned list-sessions and
# display-message output, then exercise _vibe_sessions_matching_cwd.
# Each case writes its expected fake-tmux output into a file the shim reads.
_VIBE_SH="$_REPO_DIR/shell/vibe.bash"

cat > "$_TMP_BIN/tmux" <<'TSHIM'
#!/usr/bin/env bash
# Fake tmux for smoke tests. Reads canned output from $TMUX_FAKE_FILE
# based on the first arg + subcommand.
set -e
case "$1" in
  list-sessions)
    # echo names (one per line) from $TMUX_FAKE_SESSIONS
    [[ -n "${TMUX_FAKE_SESSIONS:-}" ]] && printf '%s\n' $TMUX_FAKE_SESSIONS
    exit 0
    ;;
  display-message)
    # last arg is target spec like "-t name". We look up $TMUX_FAKE_CWD_<name>.
    target=""
    for a in "$@"; do
      [[ "$prev" == "-t" ]] && target="$a"
      prev="$a"
    done
    # printf (not echo) to avoid trailing newline corrupting the var name
    var="TMUX_FAKE_CWD_$(printf '%s' "$target" | tr -c 'A-Za-z0-9' '_')"
    eval "printf '%s\n' \"\${$var:-}\""
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
TSHIM
chmod +x "$_TMP_BIN/tmux"

run_match() {
  local target="$1"
  env -i HOME="$HOME" PATH="$_TMP_BIN:$PATH" VIBE_HOME="$_REPO_DIR" \
      TMUX_FAKE_SESSIONS="${TMUX_FAKE_SESSIONS:-}" \
      TMUX_FAKE_CWD_vibe_boldfox="${TMUX_FAKE_CWD_vibe_boldfox:-}" \
      TMUX_FAKE_CWD_vibe_featurex="${TMUX_FAKE_CWD_vibe_featurex:-}" \
      TMUX_FAKE_CWD_vibe_quietowl="${TMUX_FAKE_CWD_vibe_quietowl:-}" \
      TMUX_FAKE_CWD_misc_session="${TMUX_FAKE_CWD_misc_session:-}" \
      bash -c "
        source \"$_VIBE_SH\"
        _vibe_sessions_matching_cwd \"$target\"
      "
}

# Case 1: 0 sessions
TMUX_FAKE_SESSIONS=""
got="$(run_match /any/path)"
assert_eq "${got:-<empty>}" "<empty>" "matching cwd: 0 sessions → empty"

# Case 2: 1 vibe-* session, cwd matches
TMUX_FAKE_SESSIONS="vibe-boldfox"
TMUX_FAKE_CWD_vibe_boldfox="/home/u/projectA"
got="$(run_match /home/u/projectA)"
assert_eq "$got" "vibe-boldfox" "matching cwd: 1 match → name returned"

# Case 3: 1 vibe-* session, cwd does NOT match
got="$(run_match /home/u/elsewhere)"
assert_eq "${got:-<empty>}" "<empty>" "matching cwd: 1 session, no match → empty"

# Case 4: vibe-* mixed with non-vibe (only vibe-* should be considered)
TMUX_FAKE_SESSIONS="vibe-boldfox misc-session"
TMUX_FAKE_CWD_vibe_boldfox="/home/u/projectA"
TMUX_FAKE_CWD_misc_session="/home/u/projectA"
got="$(run_match /home/u/projectA)"
assert_eq "$got" "vibe-boldfox" "matching cwd: non-vibe-* session is filtered out"

# Case 5: multiple matches, deterministic order (list-sessions order is preserved)
TMUX_FAKE_SESSIONS="vibe-boldfox vibe-featurex vibe-quietowl"
TMUX_FAKE_CWD_vibe_boldfox="/home/u/projectA"
TMUX_FAKE_CWD_vibe_featurex="/home/u/projectA"
TMUX_FAKE_CWD_vibe_quietowl="/home/u/scratch"
got="$(run_match /home/u/projectA | tr '\n' ',' | sed 's/,$//')"
assert_eq "$got" "vibe-boldfox,vibe-featurex" "matching cwd: N matches, ordered"

# Cleanup the tmux stub so subsequent E2E section uses real tmux if present
rm -f "$_TMP_BIN/tmux"

###############################################################################
section "Real-API smoke (opt-in)"
###############################################################################

if [[ "${CC_SMOKE_REAL_API:-0}" == "1" ]]; then
  skip "CC_SMOKE_REAL_API=1 set but real-API harness not implemented in smoke.sh"
else
  skip "real-API tests (set CC_SMOKE_REAL_API=1 to opt in; not implemented here)"
fi

###############################################################################
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
