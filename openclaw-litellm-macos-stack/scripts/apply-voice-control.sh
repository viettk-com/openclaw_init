#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/apply-voice-control.sh [--dry-run]

What it does:
  - validates the voice bot env
  - enables OpenClaw gateway.http.endpoints.chatCompletions in template + runtime config
  - starts whisper + voicebot-python with docker compose overlay
  - force-recreates openclaw-gateway and openclaw-cli so the new HTTP config is active
EOF
}

ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd" >&2
    exit 1
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
  echo "Timeout waiting for $url" >&2
  exit 1
}

DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

ensure_cmd docker
ensure_cmd python3
ensure_cmd curl

if [[ ! -f .env ]]; then
  echo "Missing .env in ${ROOT_DIR}" >&2
  exit 1
fi

set -a
. ./.env
set +a

if [[ -z "${VOICEBOT_TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "VOICEBOT_TELEGRAM_BOT_TOKEN is required." >&2
  exit 1
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && "${VOICEBOT_TELEGRAM_BOT_TOKEN}" == "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo "VOICEBOT_TELEGRAM_BOT_TOKEN must be different from TELEGRAM_BOT_TOKEN to avoid competing Telegram consumers." >&2
  exit 1
fi

MODEL_FILE="${WHISPER_CPP_MODEL_FILE:-ggml-base.bin}"
MODEL_PATH="${ROOT_DIR}/data/whisper/models/${MODEL_FILE}"
if [[ ! -f "${MODEL_PATH}" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] whisper model is not downloaded yet: ${MODEL_PATH}"
  else
    echo "Missing whisper model at ${MODEL_PATH}" >&2
    echo "Run ./scripts/download-whisper-model.sh ${WHISPER_CPP_MODEL_NAME:-base} first." >&2
    exit 1
  fi
fi

TEMPLATE_JSON="${ROOT_DIR}/config/openclaw.json"
RUNTIME_JSON="${ROOT_DIR}/data/openclaw/config/openclaw.json"

python3 - "$TEMPLATE_JSON" "$RUNTIME_JSON" "$DRY_RUN" <<'PY'
import json
import pathlib
import shutil
import sys
import time

template = pathlib.Path(sys.argv[1])
runtime = pathlib.Path(sys.argv[2])
dry_run = sys.argv[3] == "1"

for path in (template, runtime):
    data = json.loads(path.read_text())
    chat = (
        data.setdefault("gateway", {})
        .setdefault("http", {})
        .setdefault("endpoints", {})
        .setdefault("chatCompletions", {})
    )
    already_enabled = bool(chat.get("enabled"))
    chat["enabled"] = True
    if dry_run:
        print(f"[dry-run] would set chatCompletions.enabled=true in {path} (already_enabled={already_enabled})")
        continue

    backup_path = path.with_name(path.name + f".bak-voice-{int(time.time())}")
    shutil.copy2(path, backup_path)
    path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Updated {path} (backup: {backup_path})")
PY

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would run docker compose overlay for whisper + voicebot-python + openclaw-gateway + openclaw-cli"
  exit 0
fi

env \
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
  LITELLM_SALT_KEY="${LITELLM_SALT_KEY}" \
  LITELLM_API_KEY="${LITELLM_API_KEY}" \
  OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}" \
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
  VOICEBOT_TELEGRAM_BOT_TOKEN="${VOICEBOT_TELEGRAM_BOT_TOKEN}" \
  docker compose -f docker-compose.yml -f docker-compose.voice.yml config >/dev/null

docker compose -f docker-compose.yml -f docker-compose.voice.yml up -d --build --force-recreate \
  whisper voicebot-python openclaw-gateway openclaw-cli

OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 60 2

echo
echo "Voice control stack is up."
echo "OpenClaw ready: http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz"
echo "Voice bot Telegram token is isolated from the main OpenClaw bot."
echo "Next step: ./scripts/test-voice-control.sh"
