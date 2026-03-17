#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

wait_for_http() {
  local url="$1"
  local retries="${2:-60}"
  local sleep_s="${3:-2}"
  local auth_header="${4:-}"
  local i
  for ((i = 1; i <= retries; i += 1)); do
    if [[ -n "$auth_header" ]]; then
      if curl -fsS -H "$auth_header" "$url" >/dev/null 2>&1; then
        return 0
      fi
    else
      if curl -fsS "$url" >/dev/null 2>&1; then
        return 0
      fi
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

ensure_cmd python3
ensure_cmd docker
ensure_cmd curl
ensure_cmd brew

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

set -a
. ./.env
set +a

if [[ -z "${CLIPROXY_API_KEY:-}" ]]; then
  echo "CLIPROXY_API_KEY is empty in .env"
  exit 1
fi

if [[ "${CLIPROXY_ENABLE:-1}" =~ ^(0|false|False|FALSE|no|No|NO|off|OFF)$ ]]; then
  echo "CLIPROXY_ENABLE is disabled in .env"
  exit 1
fi

if ! brew list cliproxyapi >/dev/null 2>&1; then
  brew install cliproxyapi
fi

python3 ./scripts/render-cliproxy-config.py
python3 ./scripts/sync-cliproxy-codex-auth.py

BREW_PREFIX="$(brew --prefix)"
CLIPROXY_ETC="${BREW_PREFIX}/etc/cliproxyapi.conf"
cp ./config/cliproxyapi-config.yaml "$CLIPROXY_ETC"

if ! brew services restart cliproxyapi >/dev/null 2>&1; then
  brew services start cliproxyapi >/dev/null
fi

CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
wait_for_http "http://127.0.0.1:${CLIPROXY_PORT}/v1/models" 90 2 "Authorization: Bearer ${CLIPROXY_API_KEY}"

docker exec oc-litellm env CLIPROXY_API_BASE="${CLIPROXY_API_BASE}" CLIPROXY_API_KEY="${CLIPROXY_API_KEY}" python - <<'PY'
import json
import os
import urllib.request

url = os.environ["CLIPROXY_API_BASE"].rstrip("/") + "/models"
req = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Bearer {os.environ['CLIPROXY_API_KEY']}",
        "Content-Type": "application/json",
    },
)
with urllib.request.urlopen(req, timeout=10) as resp:
    data = json.load(resp)
    models = [item.get("id") for item in (data.get("data") or [])[:5]]
    print("CLIProxyAPI reachable from LiteLLM container. Sample models:", ", ".join(models))
PY

python3 ./scripts/render-litellm-config.py
docker compose up -d --force-recreate litellm openclaw-gateway openclaw-cli

LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_HEALTH_PORT="${LITELLM_HEALTH_PORT:-8001}"
OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

wait_for_http "http://${LITELLM_BIND_HOST}:${LITELLM_HEALTH_PORT}/health/readiness" 90 2
wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 90 2

echo "CLIProxyAPI bridge is ready."
echo "Host models:"
curl -fsS -H "Authorization: Bearer ${CLIPROXY_API_KEY}" "http://127.0.0.1:${CLIPROXY_PORT}/v1/models"
echo
