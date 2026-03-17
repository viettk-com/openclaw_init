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

models = ["claude-opus-4-6", "gpt-5.4", "gpt-5.3-codex", "MiniMax-M2.5", "MiniMax-M2.1"]

dlg_enabled = os.environ.get("DANGLAMGIAU_ENABLE", "0").strip().lower() not in {"0", "false", "no", "off"}
dlg_key = os.environ.get("DANGLAMGIAU_API_KEY", "").strip()
dlg_base = os.environ.get("DANGLAMGIAU_API_BASE", "").strip()
if dlg_enabled and dlg_key and dlg_base:
    prefix = os.environ.get("DANGLAMGIAU_MODEL_PREFIX", "dlg").strip() or "dlg"
    for raw in os.environ.get(
        "DANGLAMGIAU_MODELS", "gpt-5,gpt-5-codex"
    ).split(","):
        model = raw.strip()
        if not model:
            continue
        alias = f"{prefix}-{model.replace('/', '-').replace('.', '-')}"
        if alias not in models:
            models.append(alias)

claudible_enabled = os.environ.get("CLAUDIBLE_ENABLE", "0").strip().lower() not in {"0", "false", "no", "off"}
claudible_key = os.environ.get("CLAUDIBLE_API_KEY", "").strip()
claudible_base = os.environ.get("CLAUDIBLE_API_BASE", "").strip()
if claudible_enabled and claudible_key and claudible_base:
    prefix = os.environ.get("CLAUDIBLE_MODEL_PREFIX", "claudible").strip() or "claudible"
    for raw in os.environ.get(
        "CLAUDIBLE_MODELS", "claude-sonnet-4.6,claude-opus-4.6,claude-haiku-4.5"
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
        "CLIPROXY_MODELS", "gpt-5.4,gpt-5.3-codex"
    ).split(","):
        model = raw.strip()
        if not model:
            continue
        alias_candidates = [f"codex-oauth-{model.replace('/', '-').replace('.', '-')}"]
        if model in {"gpt-5.4", "gpt-5.3-codex"}:
            alias_candidates.insert(0, model)
        for alias in alias_candidates:
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

PAYLOAD="${PAYLOAD}" python3 - <<'PY'
import os
import sys
import urllib.error
import urllib.request

request = urllib.request.Request(
    f"http://{os.environ['LITELLM_BIND_HOST']}:{os.environ['LITELLM_PORT']}/key/generate",
    data=os.environ["PAYLOAD"].encode(),
    headers={
        "Authorization": f"Bearer {os.environ['LITELLM_MASTER_KEY']}",
        "Content-Type": "application/json",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=30) as response:
        sys.stdout.write(response.read().decode())
except urllib.error.HTTPError as exc:
    sys.stderr.write(exc.read().decode(errors="ignore"))
    raise
PY

echo
echo "Copy the generated key into .env as LITELLM_API_KEY=..."
