#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

wait_for_http() {
  local url="$1"
  local retries="${2:-60}"
  local sleep_s="${3:-2}"
  local i
  for ((i = 1; i <= retries; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  echo "Timeout waiting for $url"
  return 1
}

ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd"
    exit 1
  fi
}

ensure_cmd curl
ensure_cmd python3
ensure_cmd docker

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

set -a
. ./.env
set +a

LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_HEALTH_PORT="${LITELLM_HEALTH_PORT:-8001}"
OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_CONTAINER="${OPENCLAW_CONTAINER:-oc-openclaw-gateway}"
GPT_MODEL="${GPT_MODEL:-gpt-5.1-codex}"
MINIMAX_MODEL="${MINIMAX_MODEL:-MiniMax-M2.5}"
TELEGRAM_CHANNEL="${TELEGRAM_CHANNEL:-telegram}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"
SKIP_GPT="${SKIP_GPT:-0}"
SKIP_MINIMAX="${SKIP_MINIMAX:-0}"
SKIP_TELEGRAM="${SKIP_TELEGRAM:-0}"

declare -a SUMMARY_LINES=()
FAILURES=0

append_summary() {
  local status="$1"
  local name="$2"
  local detail="$3"
  SUMMARY_LINES+=("[$status] $name - $detail")
  if [[ "$status" == "FAIL" ]]; then
    FAILURES=$((FAILURES + 1))
  fi
}

first_telegram_target() {
  python3 - "$ROOT_DIR/data/openclaw/config/credentials/telegram-allowFrom.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit("")

try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit("")

allow_from = data.get("allowFrom") or []
if allow_from:
    print(str(allow_from[0]))
PY
}

run_model_test() {
  local label="$1"
  local model="$2"
  local prompt="$3"
  local extra_json="$4"

  local payload
  payload="$(python3 - "$model" "$prompt" "$extra_json" <<'PY'
import json
import sys

model = sys.argv[1]
prompt = sys.argv[2]
extra_json = sys.argv[3]
payload = {
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 64,
}
if extra_json:
    payload.update(json.loads(extra_json))
print(json.dumps(payload))
PY
)"

  local response_file
  response_file="$(mktemp)"
  local http_code="000"
  local curl_exit=0
  http_code="$(
    curl -sS -o "$response_file" -w '%{http_code}' \
      "http://${LITELLM_BIND_HOST}:${LITELLM_PORT}/v1/chat/completions" \
      -H "Authorization: Bearer ${LITELLM_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$payload"
  )" || curl_exit=$?

  if [[ "$curl_exit" -ne 0 ]]; then
    append_summary "FAIL" "$label" "curl error ${curl_exit}"
    rm -f "$response_file"
    return
  fi

  if [[ "$http_code" != "200" ]]; then
    local error_text
    error_text="$(python3 - "$response_file" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_text(errors="ignore").strip()
if not raw:
    print("empty response")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print(raw[:240].replace("\n", " "))
    raise SystemExit(0)

error = data.get("error") or {}
message = error.get("message") or raw
print(str(message).replace("\n", " ")[:240])
PY
)"
    append_summary "FAIL" "$label" "HTTP ${http_code}: ${error_text}"
    rm -f "$response_file"
    return
  fi

  local snippet
  snippet="$(python3 - "$response_file" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
choice = ((data.get("choices") or [{}])[0].get("message") or {})
content = choice.get("content")
reasoning = choice.get("reasoning_content") or (choice.get("provider_specific_fields") or {}).get("reasoning_content")
model = data.get("model") or "unknown"
text = ""
if isinstance(content, str) and content.strip():
    text = content.strip()
elif isinstance(reasoning, str) and reasoning.strip():
    text = reasoning.strip()
if not text:
    text = "response received"
print(f"model={model} snippet={text[:160].replace(chr(10), ' ')}")
PY
)"
  append_summary "PASS" "$label" "$snippet"
  rm -f "$response_file"
}

run_telegram_test() {
  if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    append_summary "SKIP" "Telegram" "TELEGRAM_BOT_TOKEN is empty"
    return
  fi

  if [[ -z "$TELEGRAM_TARGET" ]]; then
    TELEGRAM_TARGET="$(first_telegram_target || true)"
  fi

  if [[ -z "$TELEGRAM_TARGET" ]]; then
    append_summary "SKIP" "Telegram" "no paired Telegram target found; set TELEGRAM_TARGET=<chat_id>"
    return
  fi

  local marker="TG_E2E_$(date +%Y%m%d%H%M%S)"
  local prompt="Reply with exactly ${marker}. No punctuation, no markdown."
  local response_file
  response_file="$(mktemp)"
  local agent_exit=0

  docker exec "$OPENCLAW_CONTAINER" node dist/index.js \
    agent \
    --channel "$TELEGRAM_CHANNEL" \
    --to "$TELEGRAM_TARGET" \
    --message "$prompt" \
    --deliver \
    --json >"$response_file" 2>&1 || agent_exit=$?

  if [[ "$agent_exit" -ne 0 ]]; then
    append_summary "FAIL" "Telegram" "agent command failed: $(tr '\n' ' ' <"$response_file" | head -c 240)"
    rm -f "$response_file"
    return
  fi

  local telegram_result
  telegram_result="$(python3 - "$response_file" "$marker" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
raw = path.read_text(errors="ignore").strip()
start = raw.find("{")
if start == -1:
    print("FAIL|no JSON payload returned from agent command")
    raise SystemExit(0)

data = json.loads(raw[start:])
status = data.get("status")
payloads = ((data.get("result") or {}).get("payloads") or [])
text = ""
if payloads:
    text = str((payloads[0] or {}).get("text") or "").strip()
model = (((data.get("result") or {}).get("meta") or {}).get("agentMeta") or {}).get("model") or "unknown"

if status != "ok":
    print(f"FAIL|status={status!r}")
elif text != marker:
    print(f"FAIL|model={model} returned {text!r}, expected {marker!r}")
else:
    print(f"PASS|model={model} delivered {marker}")
PY
)"

  if [[ "$telegram_result" == PASS\|* ]]; then
    append_summary "PASS" "Telegram" "${telegram_result#PASS|}"
  else
    append_summary "FAIL" "Telegram" "${telegram_result#FAIL|}"
  fi

  rm -f "$response_file"
}

wait_for_http "http://${LITELLM_BIND_HOST}:${LITELLM_HEALTH_PORT}/health/readiness" 60 2
wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 60 2

if [[ "$SKIP_GPT" == "1" ]]; then
  append_summary "SKIP" "GPT" "SKIP_GPT=1"
elif [[ -z "${OPENAI_API_KEY:-}" && -z "${OPENAI_API_KEY_2:-}" && -z "${OPENAI_API_KEY_3:-}" && -z "${OPENAI_API_KEY_4:-}" ]]; then
  append_summary "SKIP" "GPT" "no OPENAI_API_KEY configured"
else
  run_model_test "GPT" "$GPT_MODEL" "Reply with exactly GPT_OK." ""
fi

if [[ "$SKIP_MINIMAX" == "1" ]]; then
  append_summary "SKIP" "MiniMax" "SKIP_MINIMAX=1"
elif [[ -z "${MINIMAX_API_KEY:-}" ]]; then
  append_summary "SKIP" "MiniMax" "no MINIMAX_API_KEY configured"
else
  run_model_test "MiniMax" "$MINIMAX_MODEL" "Reply with exactly MINIMAX_OK." '{"reasoning_effort":"medium"}'
fi

if [[ "$SKIP_TELEGRAM" == "1" ]]; then
  append_summary "SKIP" "Telegram" "SKIP_TELEGRAM=1"
else
  run_telegram_test
fi

echo "OpenClaw smoke test summary:"
for line in "${SUMMARY_LINES[@]}"; do
  echo "  $line"
done

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
