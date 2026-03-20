#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd" >&2
    exit 1
  fi
}

ensure_cmd bash
ensure_cmd python3
ensure_cmd docker

TEMP_ENV_CREATED=0
cleanup() {
  if [[ "$TEMP_ENV_CREATED" -eq 1 ]]; then
    rm -f "${ROOT_DIR}/.env"
  fi
}
trap cleanup EXIT

SUMMARY=()
FAILURES=0

pass() {
  SUMMARY+=("[PASS] $1")
}

warn() {
  SUMMARY+=("[WARN] $1")
}

fail() {
  SUMMARY+=("[FAIL] $1")
  FAILURES=$((FAILURES + 1))
}

run_check() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

run_check "bash syntax: download-whisper-model.sh" bash -n ./scripts/download-whisper-model.sh
run_check "bash syntax: apply-voice-control.sh" bash -n ./scripts/apply-voice-control.sh
run_check "bash syntax: test-voice-control.sh" bash -n ./scripts/test-voice-control.sh
run_check "python syntax: voice bot" env PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/openclaw-pyc" python3 -m py_compile ./voicebot-python/bot.py
run_check "voice bot self-test" python3 ./voicebot-python/bot.py --self-test

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  cat >>"${ROOT_DIR}/.env" <<'EOF'
POSTGRES_PASSWORD=dummy-postgres
LITELLM_MASTER_KEY=sk-dummy-master
LITELLM_SALT_KEY=sk-dummy-salt
LITELLM_API_KEY=sk-dummy-api
OPENCLAW_GATEWAY_TOKEN=dummy-openclaw-token
TELEGRAM_BOT_TOKEN=dummy-main-bot
VOICEBOT_TELEGRAM_BOT_TOKEN=dummy-voice-bot
EOF
  TEMP_ENV_CREATED=1
  warn "created temporary .env for compose validation"
fi

if env \
  POSTGRES_PASSWORD=dummy-postgres \
  LITELLM_MASTER_KEY=sk-dummy-master \
  LITELLM_SALT_KEY=sk-dummy-salt \
  LITELLM_API_KEY=sk-dummy-api \
  OPENCLAW_GATEWAY_TOKEN=dummy-openclaw-token \
  TELEGRAM_BOT_TOKEN=dummy-main-bot \
  VOICEBOT_TELEGRAM_BOT_TOKEN=dummy-voice-bot \
  docker compose -f docker-compose.yml -f docker-compose.voice.yml config >/dev/null
then
  pass "docker compose config with voice overlay"
else
  fail "docker compose config with voice overlay"
fi

python3 - "$ROOT_DIR/config/openclaw.json" "$ROOT_DIR/data/openclaw/config/openclaw.json" <<'PY'
import json
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    data = json.loads(path.read_text())
    enabled = (
        data.get("gateway", {})
        .get("http", {})
        .get("endpoints", {})
        .get("chatCompletions", {})
        .get("enabled", False)
    )
    print(f"{path}: chatCompletions.enabled={enabled}")
PY

if [[ ! -f "${ROOT_DIR}/data/whisper/models/${WHISPER_CPP_MODEL_FILE:-ggml-base.bin}" ]]; then
  warn "whisper model file is not downloaded yet"
else
  pass "whisper model file exists"
fi

echo
printf '%s\n' "${SUMMARY[@]}"

if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
