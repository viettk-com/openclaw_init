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

ensure_cmd docker
ensure_cmd curl

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

mkdir -p ./data/openclaw/claude

set -a
. ./.env
set +a

docker compose build openclaw-gateway openclaw-cli
docker compose up -d --force-recreate openclaw-gateway

OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 90 2

# Smoke test the CLI image without keeping an extra long-lived container around.
docker compose run --rm openclaw-cli --help >/dev/null

docker compose exec -T openclaw-gateway sh -lc 'command -v claude && claude --version'

auth_status="$(docker compose exec -T openclaw-gateway claude auth status 2>/dev/null || true)"

if printf '%s' "$auth_status" | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
  echo "Claude Code auth is ready inside the gateway container."
else
  echo "Claude Code is installed, but not logged in yet."
  echo "Run: ./scripts/claude-code.sh auth login"
fi

echo "Claude Code backend is ready."
echo "Examples:"
echo "  ./scripts/claude-code.sh auth status"
echo "  docker compose run --rm openclaw-cli models set claude-cli/opus"
echo "  docker compose run --rm openclaw-cli models set claude-cli/sonnet"
