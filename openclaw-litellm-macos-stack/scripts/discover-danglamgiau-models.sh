#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

set -a
. ./.env
set +a

if [[ -z "${DANGLAMGIAU_API_KEY:-}" ]]; then
  echo "DANGLAMGIAU_API_KEY is empty in .env"
  exit 1
fi

API_BASE="${DANGLAMGIAU_API_BASE:-https://danglamgiau.com/v1}"
URL="${API_BASE%/}/models"

curl -fsS "$URL" \
  -H "Authorization: Bearer ${DANGLAMGIAU_API_KEY}" \
  -H "Content-Type: application/json" \
| python3 - <<'PY'
import json
import sys

data = json.load(sys.stdin)
models = data.get("data") or []
if not models:
    print("No models returned.")
    raise SystemExit(0)

for item in sorted(models, key=lambda row: str(row.get("id") or "")):
    model_id = item.get("id") or ""
    owner = item.get("owned_by") or "unknown"
    print(f"{model_id}\t{owner}")
PY
