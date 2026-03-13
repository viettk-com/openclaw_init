#!/usr/bin/env bash
set -euo pipefail

if [[ "${OSTYPE:-}" == darwin* ]]; then
  echo "Script nay danh cho Ubuntu/Linux, khong phai macOS."
  exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-stack}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclawstack}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
LITELLM_IMAGE="${LITELLM_IMAGE:-docker.litellm.ai/berriai/litellm:main-stable}"
OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_HEALTH_PORT="${LITELLM_HEALTH_PORT:-8001}"
POSTGRES_DB="${POSTGRES_DB:-litellm}"
POSTGRES_USER="${POSTGRES_USER:-litellm}"
PRIMARY_MODEL="${PRIMARY_MODEL:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_API_KEY_2="${OPENAI_API_KEY_2:-}"
OPENAI_API_KEY_3="${OPENAI_API_KEY_3:-}"
OPENAI_API_KEY_4="${OPENAI_API_KEY_4:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
MINIMAX_API_KEY="${MINIMAX_API_KEY:-}"
MINIMAX_API_BASE="${MINIMAX_API_BASE:-https://api.minimax.io/v1}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
LITELLM_SALT_KEY="${LITELLM_SALT_KEY:-}"
LITELLM_API_KEY="${LITELLM_API_KEY:-}"

rand_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    python3 - <<PY
import secrets
print(secrets.token_hex($bytes))
PY
  fi
}

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

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker chua duoc cai. Dang cai bang get.docker.com ..."
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin chua san sang."
  exit 1
fi

HAS_OPENAI_KEY="false"
if [[ -n "$OPENAI_API_KEY" || -n "$OPENAI_API_KEY_2" || -n "$OPENAI_API_KEY_3" || -n "$OPENAI_API_KEY_4" ]]; then
  HAS_OPENAI_KEY="true"
fi

HAS_MINIMAX_KEY="false"
if [[ -n "$MINIMAX_API_KEY" ]]; then
  HAS_MINIMAX_KEY="true"
fi

if [[ "$HAS_OPENAI_KEY" != "true" && "$HAS_MINIMAX_KEY" != "true" && -z "$ANTHROPIC_API_KEY" ]]; then
  echo "Warning: OPENAI_API_KEY va ANTHROPIC_API_KEY deu dang rong. Stack van len, nhung agent se chua tra loi duoc."
fi

if [[ -z "$PRIMARY_MODEL" ]]; then
  if [[ "$HAS_MINIMAX_KEY" == "true" ]]; then
    PRIMARY_MODEL="litellm/MiniMax-M2.5"
  elif [[ "$HAS_OPENAI_KEY" == "true" && -z "$ANTHROPIC_API_KEY" ]]; then
    PRIMARY_MODEL="litellm/gpt-5.1-codex"
  else
    PRIMARY_MODEL="litellm/claude-opus-4-6"
  fi
fi

if [[ -z "$OPENCLAW_GATEWAY_TOKEN" ]]; then
  OPENCLAW_GATEWAY_TOKEN="$(rand_hex 32)"
fi

if [[ -z "$POSTGRES_PASSWORD" ]]; then
  POSTGRES_PASSWORD="$(rand_hex 16)"
fi

if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  LITELLM_MASTER_KEY="sk-$(rand_hex 24)"
fi

if [[ -z "$LITELLM_SALT_KEY" ]]; then
  LITELLM_SALT_KEY="sk-$(rand_hex 24)"
fi

if [[ -z "$LITELLM_API_KEY" ]]; then
  LITELLM_API_KEY="$LITELLM_MASTER_KEY"
fi

mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/data/postgres" "$INSTALL_DIR/data/openclaw/config" "$INSTALL_DIR/data/openclaw/workspace" "$INSTALL_DIR/scripts"

cat >"$INSTALL_DIR/.env" <<EOF
OPENCLAW_IMAGE=$OPENCLAW_IMAGE
LITELLM_IMAGE=$LITELLM_IMAGE
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
OPENCLAW_BIND_HOST=$OPENCLAW_BIND_HOST
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$OPENCLAW_BRIDGE_PORT
OPENCLAW_GATEWAY_BIND=$OPENCLAW_GATEWAY_BIND
LITELLM_BIND_HOST=$LITELLM_BIND_HOST
LITELLM_PORT=$LITELLM_PORT
LITELLM_HEALTH_PORT=$LITELLM_HEALTH_PORT
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
LITELLM_SALT_KEY=$LITELLM_SALT_KEY
LITELLM_API_KEY=$LITELLM_API_KEY
OPENAI_API_KEY=$OPENAI_API_KEY
OPENAI_API_KEY_2=$OPENAI_API_KEY_2
OPENAI_API_KEY_3=$OPENAI_API_KEY_3
OPENAI_API_KEY_4=$OPENAI_API_KEY_4
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
MINIMAX_API_KEY=$MINIMAX_API_KEY
MINIMAX_API_BASE=$MINIMAX_API_BASE
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF

cat >"$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    container_name: oc-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-litellm}
      POSTGRES_USER: ${POSTGRES_USER:-litellm}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set in .env}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-litellm} -d ${POSTGRES_DB:-litellm}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - ai-internal

  litellm:
    image: ${LITELLM_IMAGE:-docker.litellm.ai/berriai/litellm:main-stable}
    container_name: oc-litellm
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - .env
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER:-litellm}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB:-litellm}
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY:?set in .env}
      LITELLM_SALT_KEY: ${LITELLM_SALT_KEY:?set in .env}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      STORE_MODEL_IN_DB: "True"
      LITELLM_MODE: "PRODUCTION"
      SEPARATE_HEALTH_APP: "1"
      SEPARATE_HEALTH_PORT: "8001"
      SUPERVISORD_STOPWAITSECS: "3600"
    command: ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "2"]
    volumes:
      - ./config/litellm-config.yaml:/app/config.yaml:ro
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health/readiness', timeout=5).status == 200 else 1)"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 25s
    expose:
      - "4000"
      - "8001"
    ports:
      - "${LITELLM_BIND_HOST:-127.0.0.1}:${LITELLM_PORT:-4000}:4000"
      - "${LITELLM_BIND_HOST:-127.0.0.1}:${LITELLM_HEALTH_PORT:-8001}:8001"
    networks:
      - ai-internal

  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}
    container_name: oc-openclaw-gateway
    restart: unless-stopped
    init: true
    depends_on:
      litellm:
        condition: service_healthy
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:-}
      LITELLM_API_KEY: ${LITELLM_API_KEY:?set in .env}
    command: ["node", "dist/index.js", "gateway", "--bind", "${OPENCLAW_GATEWAY_BIND:-lan}", "--port", "18789"]
    volumes:
      - ./data/openclaw/config:/home/node/.openclaw
      - ./data/openclaw/workspace:/home/node/.openclaw/workspace
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    ports:
      - "${OPENCLAW_BIND_HOST:-127.0.0.1}:${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "${OPENCLAW_BIND_HOST:-127.0.0.1}:${OPENCLAW_BRIDGE_PORT:-18790}:18790"
    networks:
      - ai-internal

  openclaw-cli:
    image: ${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}
    container_name: oc-openclaw-cli
    depends_on:
      openclaw-gateway:
        condition: service_healthy
    network_mode: "service:openclaw-gateway"
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node", "dist/index.js"]
    environment:
      HOME: /home/node
      TERM: xterm-256color
      BROWSER: echo
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN:-}
      OPENCLAW_ALLOW_INSECURE_PRIVATE_WS: ${OPENCLAW_ALLOW_INSECURE_PRIVATE_WS:-}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:-}
      LITELLM_API_KEY: ${LITELLM_API_KEY:?set in .env}
    volumes:
      - ./data/openclaw/config:/home/node/.openclaw
      - ./data/openclaw/workspace:/home/node/.openclaw/workspace

networks:
  ai-internal:
    name: ${COMPOSE_PROJECT_NAME:-openclawstack}_internal
    driver: bridge
    internal: false
EOF

cat >"$INSTALL_DIR/scripts/render-litellm-config.py" <<'EOF'
#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_PATH = ROOT / ".env"
OUTPUT_PATH = ROOT / "config" / "litellm-config.yaml"


def load_env(path: pathlib.Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def openai_sort_key(name: str) -> tuple[int, int, str]:
    if name == "OPENAI_API_KEY":
        return (1, 0, name)
    match = re.fullmatch(r"OPENAI_API_KEY_(\d+)", name)
    if match is None:
        return (10**9, 0, name)
    return (int(match.group(1)), 1, name)


env = load_env(ENV_PATH)

openai_var_names = sorted(
    [
        key
        for key in env
        if key == "OPENAI_API_KEY" or re.fullmatch(r"OPENAI_API_KEY_\d+", key)
    ],
    key=openai_sort_key,
)

active_openai_vars: list[str] = []
seen_openai_values: set[str] = set()
for name in openai_var_names:
    value = env.get(name, "")
    if not value:
        continue
    if value in seen_openai_values:
        continue
    seen_openai_values.add(value)
    active_openai_vars.append(name)

anthropic_enabled = bool(env.get("ANTHROPIC_API_KEY", "").strip())
minimax_enabled = bool(env.get("MINIMAX_API_KEY", "").strip())
has_real_provider_keys = anthropic_enabled or bool(active_openai_vars) or minimax_enabled

lines: list[str] = [
    "# Generated by scripts/render-litellm-config.py from .env",
]

if active_openai_vars:
    lines.append("# Active OpenAI key env vars: " + ", ".join(active_openai_vars))
if len(active_openai_vars) > 1:
    lines.append(
        "# LiteLLM will load-balance across repeated gpt-5.1-codex deployments."
    )
if not has_real_provider_keys:
    lines.append(
        "# No non-empty provider keys found yet; keeping placeholder deployments so initial boot stays compatible."
    )

lines.append("model_list:")

if anthropic_enabled or not has_real_provider_keys:
    lines.extend(
        [
            "  - model_name: claude-opus-4-6",
            "    litellm_params:",
            "      model: anthropic/claude-opus-4-6",
            "      api_key: os.environ/ANTHROPIC_API_KEY",
            "",
        ]
    )

if active_openai_vars:
    for name in active_openai_vars:
        lines.extend(
            [
                "  - model_name: gpt-5.1-codex",
                "    litellm_params:",
                "      model: openai/gpt-5.1-codex",
                f"      api_key: os.environ/{name}",
                "",
            ]
        )
else:
    lines.extend(
        [
            "  - model_name: gpt-5.1-codex",
            "    litellm_params:",
            "      model: openai/gpt-5.1-codex",
            "      api_key: os.environ/OPENAI_API_KEY",
            "",
        ]
    )

if minimax_enabled:
    lines.extend(
        [
            "  - model_name: MiniMax-M2.5",
            "    litellm_params:",
            "      model: minimax/MiniMax-M2.5",
            "      api_key: os.environ/MINIMAX_API_KEY",
            "      api_base: os.environ/MINIMAX_API_BASE",
            "",
            "  - model_name: MiniMax-M2.1",
            "    litellm_params:",
            "      model: minimax/MiniMax-M2.1",
            "      api_key: os.environ/MINIMAX_API_KEY",
            "      api_base: os.environ/MINIMAX_API_BASE",
            "",
        ]
    )

lines.extend(
    [
        "general_settings:",
        "  master_key: os.environ/LITELLM_MASTER_KEY",
        "  database_url: os.environ/DATABASE_URL",
        "",
        "router_settings:",
        "  routing_strategy: simple-shuffle",
        "  num_retries: 3",
        "  retry_policy:",
        "    AuthenticationErrorRetries: 3",
        "    RateLimitErrorRetries: 3",
        "    TimeoutErrorRetries: 3",
        "    InternalServerErrorRetries: 3",
        "",
        "litellm_settings:",
        "  drop_params: true",
        "  set_verbose: false",
        "  json_logs: true",
    ]
)

OUTPUT_PATH.write_text("\n".join(lines) + "\n")
print(f"Rendered {OUTPUT_PATH}")
EOF

cat >"$INSTALL_DIR/scripts/apply-provider-config.sh" <<'EOF'
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

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

python3 ./scripts/render-litellm-config.py

set -a
. ./.env
set +a

LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_HEALTH_PORT="${LITELLM_HEALTH_PORT:-8001}"
OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

docker compose up -d --force-recreate litellm openclaw-gateway openclaw-cli

wait_for_http "http://${LITELLM_BIND_HOST}:${LITELLM_HEALTH_PORT}/health/readiness" 60 2
wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 60 2

echo "Provider config applied."
echo "LiteLLM: http://${LITELLM_BIND_HOST}:${LITELLM_PORT}/v1/models"
echo "OpenClaw: http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz"
EOF

cat >"$INSTALL_DIR/scripts/test-model.sh" <<'EOF'
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
EOF

chmod +x "$INSTALL_DIR/scripts/render-litellm-config.py" "$INSTALL_DIR/scripts/apply-provider-config.sh" "$INSTALL_DIR/scripts/test-model.sh"

TELEGRAM_ENABLED="false"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  TELEGRAM_ENABLED="true"
fi

cat >"$INSTALL_DIR/config/openclaw.json" <<EOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "$PRIMARY_MODEL"
      },
      "models": {
        "litellm/claude-opus-4-6": {
          "alias": "Claude Opus 4.6 via LiteLLM"
        },
        "litellm/gpt-5.1-codex": {
          "alias": "GPT-5.1 Codex via LiteLLM"
        },
        "litellm/MiniMax-M2.5": {
          "alias": "MiniMax M2.5 via LiteLLM"
        },
        "litellm/MiniMax-M2.1": {
          "alias": "MiniMax M2.1 via LiteLLM"
        }
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "litellm": {
        "baseUrl": "http://litellm:4000",
        "apiKey": "\${LITELLM_API_KEY}",
        "api": "openai-completions",
        "models": [
          {
            "id": "claude-opus-4-6",
            "name": "Claude Opus 4.6",
            "reasoning": true,
            "input": ["text", "image"],
            "contextWindow": 200000,
            "maxTokens": 64000
          },
          {
            "id": "gpt-5.1-codex",
            "name": "GPT-5.1 Codex",
            "reasoning": true,
            "input": ["text", "image"],
            "contextWindow": 400000,
            "maxTokens": 128000
          },
          {
            "id": "MiniMax-M2.5",
            "name": "MiniMax M2.5",
            "reasoning": true,
            "input": ["text", "image"],
            "contextWindow": 196608,
            "maxTokens": 8192
          },
          {
            "id": "MiniMax-M2.1",
            "name": "MiniMax M2.1",
            "reasoning": true,
            "input": ["text", "image"],
            "contextWindow": 196608,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "allowedOrigins": ["http://127.0.0.1:$OPENCLAW_GATEWAY_PORT"]
    }
  },
  "channels": {
    "telegram": {
      "enabled": $TELEGRAM_ENABLED,
      "botToken": "\${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "pairing",
      "configWrites": false,
      "groups": {
        "*": {
          "requireMention": true
        }
      }
    }
  }
}
EOF

cp "$INSTALL_DIR/config/openclaw.json" "$INSTALL_DIR/data/openclaw/config/openclaw.json"

python3 "$INSTALL_DIR/scripts/render-litellm-config.py"

echo "Starting OpenClaw stack in $INSTALL_DIR ..."
(
  cd "$INSTALL_DIR"
  docker compose up -d
)

wait_for_http "http://127.0.0.1:${LITELLM_HEALTH_PORT}/health/readiness" 90 2
wait_for_http "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/readyz" 90 2

VIRTUAL_KEY="$(curl -fsS "http://127.0.0.1:${LITELLM_PORT}/key/generate" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  --data '{"models":["claude-opus-4-6","gpt-5.1-codex","MiniMax-M2.5","MiniMax-M2.1"],"metadata":{"app":"openclaw","owner":"ubuntu-auto"},"key_alias":"openclaw","duration":"30d"}' \
  | python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
print(data["key"])
PY
)"

python3 - "$INSTALL_DIR/.env" "$VIRTUAL_KEY" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
value = sys.argv[2]
lines = path.read_text().splitlines()
out = []
updated = False
for line in lines:
    if line.startswith("LITELLM_API_KEY="):
        out.append(f"LITELLM_API_KEY={value}")
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"LITELLM_API_KEY={value}")
path.write_text("\n".join(out) + "\n")
PY

(
  cd "$INSTALL_DIR"
  docker compose up -d --force-recreate openclaw-gateway openclaw-cli
)

wait_for_http "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/readyz" 90 2

echo
echo "OpenClaw Ubuntu stack is ready."
echo "Install dir: $INSTALL_DIR"
echo "Dashboard: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/#token=${OPENCLAW_GATEWAY_TOKEN}"
echo "Provider update script: $INSTALL_DIR/scripts/apply-provider-config.sh"
echo "Smoke test script: $INSTALL_DIR/scripts/test-model.sh"
echo
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "Telegram bot da duoc bat. Pairing user Telegram se la buoc rieng khi co nguoi DM bot."
fi
