#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  echo "Missing .env in current directory"
  exit 1
fi

set -a
. ./.env
set +a

LITELLM_BIND_HOST="${LITELLM_BIND_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

PAYLOAD="$(
  python3 - <<'PY'
import json
import os
import time

models = ["claude-opus-4-6", "gpt-5.4", "gpt-5.1-codex", "MiniMax-M2.5", "MiniMax-M2.1"]

dlg_enabled = os.environ.get("DANGLAMGIAU_ENABLE", "0").strip().lower() not in {"0", "false", "no", "off"}
dlg_key = os.environ.get("DANGLAMGIAU_API_KEY", "").strip()
dlg_base = os.environ.get("DANGLAMGIAU_API_BASE", "").strip()
if dlg_enabled and dlg_key and dlg_base:
    prefix = os.environ.get("DANGLAMGIAU_MODEL_PREFIX", "dlg").strip() or "dlg"
    for raw in os.environ.get(
        "DANGLAMGIAU_MODELS", "gpt-5,gpt-5-codex,gpt-5.1-codex-max"
    ).split(","):
        model = raw.strip()
        if not model:
            continue
        alias = f"{prefix}-{model.replace('/', '-').replace('.', '-')}"
        if alias not in models:
            models.append(alias)

enabled = os.environ.get("CLIPROXY_ENABLE", "1").strip().lower() not in {"0", "false", "no", "off"}
cliproxy_key = os.environ.get("CLIPROXY_API_KEY", "").strip()
cliproxy_base = os.environ.get("CLIPROXY_API_BASE", "").strip()
if enabled and cliproxy_key and cliproxy_base:
    for raw in os.environ.get(
        "CLIPROXY_MODELS", "gpt-5-codex,gpt-5.1-codex,gpt-5.1-codex-max"
    ).split(","):
        model = raw.strip()
        if not model:
            continue
        alias = f"codex-oauth-{model.replace('/', '-').replace('.', '-')}"
        if alias not in models:
            models.append(alias)

payload = {
    "models": models,
    "metadata": {"app": "openclaw", "owner": "local-macos"},
    "key_alias": f"openclaw-{int(time.time())}",
    "duration": "30d",
}
print(json.dumps(payload))
PY
)"

curl --fail --silent --show-error \
  "http://${LITELLM_BIND_HOST}:${LITELLM_PORT}/key/generate" \
  --header "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  --header "Content-Type: application/json" \
  --data "${PAYLOAD}"

echo
echo "Copy the generated key into .env as LITELLM_API_KEY=..."
