# 005: LLM provider abstraction

Status: accepted

## Problem

L3 (see [001](001-three-layer-detection.md)) needs to classify ambiguous TUI tail snippets. Different users have different available API keys (DeepSeek, Anthropic, OpenAI, or a local Ollama). The wrapper must:

- Auto-detect which provider to use based on available keys.
- Send a consistent prompt regardless of provider.
- Receive a consistent JSON response shape regardless of provider.
- Fail safely (no auto-resume) when the provider is unavailable.
- Respect user privacy — pane contents leave the machine, so opt-in is required.

## Constraints

- Pure bash + curl + jq. No SDK installs.
- Must produce normalized JSON for the wrapper regardless of which provider responded.
- Must not silently swallow API errors as "looks fine, resume!" — wrong default is biased toward NOT resuming.
- Privacy: redaction enabled by default; install-time opt-in required.

## Approach

### Provider priority

`detect_provider()` returns the first non-empty match:

1. `$CC_LLM_PROVIDER` if explicitly set (`deepseek`/`claude`/`openai`/`ollama`/`none`).
2. `DEEPSEEK_API_KEY` → `deepseek`
3. `ANTHROPIC_API_KEY` → `claude`
4. `OPENAI_API_KEY` → `openai`
5. `OLLAMA_HOST` → `ollama`
6. Empty string → L3 disabled, wrapper runs in degraded mode (see [006](006-degraded-mode.md))

### Default models

| Provider | Default model | Override |
|---|---|---|
| deepseek | `deepseek-chat` | `CC_LLM_MODEL` |
| claude | `claude-haiku-4-5` | `CC_LLM_MODEL` |
| openai | `gpt-4o-mini` | `CC_LLM_MODEL` |
| ollama | `llama3.2:3b` | `CC_LLM_MODEL` |

Anthropic's Max subscription does **not** include API credits; users selecting `claude` provider pay separately. The installer must surface this.

### Request shape

All providers receive the same logical payload:

- **System prompt**: `config/classify-prompt.txt` contents (~500 tokens, fixed).
- **User content**: redacted pane tail.
- **Response format**: JSON object with fixed schema.

Per-provider curl invocations differ in URL, header, body shape, and how JSON-mode is requested:

- DeepSeek: `https://api.deepseek.com/v1/chat/completions`, OpenAI-compatible, `response_format: {"type": "json_object"}`.
- Claude (Anthropic Messages API): `https://api.anthropic.com/v1/messages`, system prompt as top-level `system` field, response JSON not strictly enforced — we prompt for it.
- OpenAI: `https://api.openai.com/v1/chat/completions`, `response_format: {"type": "json_object"}`.
- Ollama (`/api/chat`): local HTTP, `format: "json"`. **[untested]** — implemented to spec but no GPU in dev env to validate.

### Response normalization

All branches return the same JSON to the caller:

```json
{"status": "limit_hit|warning|error|normal_exit|running",
 "reset_time": "ISO 8601 or null",
 "idle": true|false,
 "modal_open": true|false,
 "reasoning": "one sentence"}
```

If the provider returns malformed JSON, an HTTP error, or hits a network timeout, `llm_classify` returns `{"status":"error","reasoning":"LLM unavailable: <detail>", ...}`. The wrapper treats this as "real error, don't auto-resume" — safe default.

### Redaction

`redact()` (default on via `CC_LLM_REDACT=1`) applies these regex replacements before sending:

- `sk-[A-Za-z0-9_-]{16,}` → `sk-REDACTED`
- `Bearer\s+[A-Za-z0-9._-]+` → `Bearer REDACTED`
- `[A-Z_]*SECRET[A-Z_]*=\S+` → `<SECRET>=REDACTED`
- `[A-Za-z0-9+/]{40,}={0,2}` → `BASE64_REDACTED` (long base64-like runs)

This is **best-effort**, not bulletproof. Documented as such in the installer banner.

## Alternatives considered

- **Use a single provider hard-coded**: rejected — user has DeepSeek key already, doesn't want Anthropic upsell, and Ollama support is requested for future-proofing.
- **Use Vercel AI SDK or LiteLLM as an abstraction layer**: extra runtime dep (Node or Python), violates the bash-only constraint.
- **Cache responses**: tempting (most pane states are stable), but caches privacy-sensitive data to disk. Skip.
- **Stream responses**: no benefit for a single-shot classification call.

## API / file layout

`lib/llm-classify.sh`:

```bash
detect_provider()     # echo provider name or empty
redact(text)          # echo redacted text on stdout
llm_classify(text)    # echo normalized JSON response on stdout, return 0/non-zero
```

`config/classify-prompt.txt` — the system prompt (English).

Env vars: `CC_LLM_PROVIDER`, `CC_LLM_MODEL`, `CC_LLM_REDACT`, plus the provider's native key var.

## What NOT to implement

- **Do not** add provider auto-fallback ("try DeepSeek, on 429 try OpenAI"). Cost and rate-limit behavior become unpredictable.
- **Do not** persist API responses to disk for analytics. Privacy.
- **Do not** add streaming or tool use — single classification call, full JSON in one round-trip.
- **Do not** add provider-specific features (e.g., Anthropic prompt caching, OpenAI batch API). Keep the abstraction thin.
- **Do not** implement Ollama auto-pull of models. User is responsible for `ollama pull llama3.2:3b` before enabling.
- **Do not** validate the Ollama branch beyond the curl call shape in this dev environment. Mark it `[untested]` until a GPU machine can run E2E.

## Test plan

- Unit: each provider's curl call, with a stubbed `curl` returning canned JSON, asserts normalized output.
- Unit: malformed JSON response → `status=error` output.
- Unit: 401/429/5xx HTTP → `status=error` output with status code in reasoning.
- Unit: `redact("sk-abc Bearer xyz APP_SECRET=foo")` produces masked output.
- Integration (per provider, optional): when key present, send a real fixture and assert real response classifies as expected. Skipped without keys.
- Ollama integration: documented as TODO, no test in v1.
