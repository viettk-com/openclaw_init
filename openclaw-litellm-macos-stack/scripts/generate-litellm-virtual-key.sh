#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "Missing .env in current directory"
  exit 1
fi

export $(grep -E '^(LITELLM_MASTER_KEY|LITELLM_PORT|LITELLM_BIND_HOST)=' .env | xargs)

LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

read -r -d '' PAYLOAD <<'JSON' || true
{
  "models": ["claude-opus-4-6", "gpt-5.1-codex", "MiniMax-M2.5", "MiniMax-M2.1"],
  "metadata": { "app": "openclaw", "owner": "local-macos" },
  "key_alias": "openclaw",
  "duration": "30d"
}
JSON

curl --fail --silent --show-error \
  "http://${LITELLM_BIND_HOST}:${LITELLM_PORT}/key/generate" \
  --header "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  --header "Content-Type: application/json" \
  --data "${PAYLOAD}"

echo
echo "Copy the generated key into .env as LITELLM_API_KEY=..."
