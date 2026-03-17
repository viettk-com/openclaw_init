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
echo "If you enabled new alias families (for example DANGLAMGIAU_* or CLIPROXY_*), regenerate a LiteLLM virtual key before switching OpenClaw to those models:"
echo "  ./scripts/generate-litellm-virtual-key.sh"
