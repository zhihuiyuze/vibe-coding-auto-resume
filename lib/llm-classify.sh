# L3 — LLM classifier. See docs/design/005-llm-provider-abstraction.md.
#
# Sourced. Exposes:
#   detect_provider          — echo provider name or empty
#   redact <text>            — echo basic-redacted text
#   llm_classify <text>      — echo normalized JSON, return 0 on success or 1 on error
#
# Network errors and malformed responses MUST emit status="error" so the wrapper
# doesn't mistakenly auto-resume on a real crash.

: "${CC_LLM_REDACT:=1}"
: "${CC_LLM_TIMEOUT:=30}"

_CC_LIB_DIR_L3="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CC_CLASSIFY_PROMPT_FILE:=$_CC_LIB_DIR_L3/../config/classify-prompt.txt}"

detect_provider() {
  # explicit override wins
  if [[ -n "${CC_LLM_PROVIDER:-}" ]]; then
    case "$CC_LLM_PROVIDER" in
      deepseek|claude|openai|ollama|none) echo "$CC_LLM_PROVIDER"; return ;;
      *) echo "" ; return 1 ;;
    esac
  fi
  if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then echo "deepseek"; return; fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo "claude"; return; fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then echo "openai"; return; fi
  if [[ -n "${OLLAMA_HOST:-}" ]]; then echo "ollama"; return; fi
  echo ""
}

# Best-effort secrets masking. Documented as not 100% reliable.
redact() {
  local in="$1"
  [[ "$CC_LLM_REDACT" == "1" ]] || { echo "$in"; return; }
  echo "$in" | sed -E \
    -e 's/sk-[A-Za-z0-9_-]{16,}/sk-REDACTED/g' \
    -e 's/Bearer[[:space:]]+[A-Za-z0-9._-]+/Bearer REDACTED/g' \
    -e 's/([A-Z_]*SECRET[A-Z_]*)=[^[:space:]]+/\1=REDACTED/g' \
    -e 's/([A-Za-z0-9+/]{40,}={0,2})/BASE64_REDACTED/g'
}

# Emit a normalized error JSON so the wrapper has a stable shape to consume.
_emit_error() {
  local reason="$1"
  jq -nc --arg r "$reason" \
    '{status:"error", reset_time:null, idle:false, modal_open:false, reasoning:$r}'
}

# Normalize a provider's response into the wrapper's expected schema. The classify
# prompt asks the LLM to already produce this shape; this function trusts it but
# falls back to error if structure is wrong.
_normalize_response() {
  local body="$1" content json
  # Many providers wrap the JSON we want inside choices[0].message.content as a string.
  content="$(jq -r 'try .choices[0].message.content // try .content[0].text // try .message.content // .' <<<"$body" 2>/dev/null)"
  [[ -z "$content" || "$content" == "null" ]] && { _emit_error "empty LLM response"; return 1; }
  # Strip markdown fences if the model added them despite instructions.
  content="${content#\`\`\`json}"
  content="${content#\`\`\`}"
  content="${content%\`\`\`}"
  json="$(jq -c '. | {status: (.status // "error"),
                     reset_time: (.reset_time // null),
                     idle: (.idle // false),
                     modal_open: (.modal_open // false),
                     reasoning: (.reasoning // "no reasoning provided")}' <<<"$content" 2>/dev/null)" \
    || { _emit_error "malformed LLM JSON: $(echo "$content" | head -c 200)"; return 1; }
  echo "$json"
}

# Common curl invocation; routes per provider.
llm_classify() {
  local pane="$1" provider system payload http body code
  provider="$(detect_provider)"
  [[ -z "$provider" || "$provider" == "none" ]] && { _emit_error "no provider configured"; return 1; }

  system="$(cat "$CC_CLASSIFY_PROMPT_FILE" 2>/dev/null)" || {
    _emit_error "classify prompt file missing"; return 1
  }
  payload="$(redact "$pane")"

  case "$provider" in
    deepseek)
      local model="${CC_LLM_MODEL:-deepseek-chat}"
      body="$(jq -nc --arg sys "$system" --arg user "$payload" --arg model "$model" '{
        model: $model,
        messages: [{role:"system", content:$sys}, {role:"user", content:$user}],
        response_format: {type:"json_object"},
        temperature: 0
      }')"
      http="$(curl -sS --max-time "$CC_LLM_TIMEOUT" -w '\n%{http_code}' \
        -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        https://api.deepseek.com/v1/chat/completions 2>&1)" || { _emit_error "deepseek curl failed: $http"; return 1; }
      ;;

    claude)
      local model="${CC_LLM_MODEL:-claude-haiku-4-5}"
      body="$(jq -nc --arg sys "$system" --arg user "$payload" --arg model "$model" '{
        model: $model,
        max_tokens: 1024,
        system: $sys,
        messages: [{role:"user", content:$user}]
      }')"
      http="$(curl -sS --max-time "$CC_LLM_TIMEOUT" -w '\n%{http_code}' \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "Content-Type: application/json" \
        -d "$body" \
        https://api.anthropic.com/v1/messages 2>&1)" || { _emit_error "claude curl failed: $http"; return 1; }
      ;;

    openai)
      local model="${CC_LLM_MODEL:-gpt-4o-mini}"
      body="$(jq -nc --arg sys "$system" --arg user "$payload" --arg model "$model" '{
        model: $model,
        messages: [{role:"system", content:$sys}, {role:"user", content:$user}],
        response_format: {type:"json_object"},
        temperature: 0
      }')"
      http="$(curl -sS --max-time "$CC_LLM_TIMEOUT" -w '\n%{http_code}' \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        https://api.openai.com/v1/chat/completions 2>&1)" || { _emit_error "openai curl failed: $http"; return 1; }
      ;;

    ollama)
      # [untested] — no GPU in dev env. Spec'd to ollama /api/chat docs.
      local model="${CC_LLM_MODEL:-llama3.2:3b}"
      body="$(jq -nc --arg sys "$system" --arg user "$payload" --arg model "$model" '{
        model: $model,
        messages: [{role:"system", content:$sys}, {role:"user", content:$user}],
        stream: false,
        format: "json",
        options: {temperature: 0}
      }')"
      http="$(curl -sS --max-time "$CC_LLM_TIMEOUT" -w '\n%{http_code}' \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${OLLAMA_HOST}/api/chat" 2>&1)" || { _emit_error "ollama curl failed: $http"; return 1; }
      ;;

    *)
      _emit_error "unknown provider: $provider"; return 1
      ;;
  esac

  # Last line is HTTP code; everything before is response body.
  code="$(tail -n1 <<<"$http")"
  body="$(head -n -1 <<<"$http")"

  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    _emit_error "$provider HTTP $code: $(echo "$body" | head -c 200)"
    return 1
  fi

  _normalize_response "$body"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    detect) detect_provider ;;
    redact) shift; redact "$*" ;;
    classify) llm_classify "$(cat)" ;;
    *) echo "usage: llm-classify.sh {detect|redact <text>|classify (text on stdin)}" >&2; exit 2 ;;
  esac
fi
