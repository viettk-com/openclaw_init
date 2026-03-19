#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  switch_openclaw_model.sh <provider/model|model> [--keep-main-session] [--skip-verify] [--dry-run]

Examples:
  switch_openclaw_model.sh litellm/gpt-5.4
  switch_openclaw_model.sh gpt-5.4 --keep-main-session
  switch_openclaw_model.sh litellm/MiniMax-M2.5 --dry-run

Defaults:
  - A bare model like gpt-5.4 is normalized to litellm/gpt-5.4.
  - The script resets agent:main:main after creating a backup, unless --keep-main-session is used.
  - The script recreates the OpenClaw gateway and runs a live verification request, unless --skip-verify is used.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

find_root() {
  local dir
  if [[ -n "${OPENCLAW_STACK_ROOT:-}" ]]; then
    if [[ -f "${OPENCLAW_STACK_ROOT}/docker-compose.yml" && -f "${OPENCLAW_STACK_ROOT}/config/openclaw.json" && -f "${OPENCLAW_STACK_ROOT}/data/openclaw/config/openclaw.json" ]]; then
      printf '%s\n' "${OPENCLAW_STACK_ROOT}"
      return 0
    fi
    echo "OPENCLAW_STACK_ROOT is set but does not look like a valid stack root: ${OPENCLAW_STACK_ROOT}" >&2
    exit 1
  fi

  if [[ -f "/Users/macos/Downloads/openclaw-litellm-macos-stack/docker-compose.yml" && -f "/Users/macos/Downloads/openclaw-litellm-macos-stack/config/openclaw.json" && -f "/Users/macos/Downloads/openclaw-litellm-macos-stack/data/openclaw/config/openclaw.json" ]]; then
    printf '%s\n' "/Users/macos/Downloads/openclaw-litellm-macos-stack"
    return 0
  fi

  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/docker-compose.yml" && -f "$dir/config/openclaw.json" && -f "$dir/data/openclaw/config/openclaw.json" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  echo "Could not locate the OpenClaw stack root from $(dirname "${BASH_SOURCE[0]}")." >&2
  exit 1
}

canonicalize_target() {
  local raw="$1"
  if [[ "$raw" == */* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  printf 'litellm/%s\n' "$raw"
}

extract_json() {
  python3 -c 'import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start == -1:
    sys.stderr.write(raw)
    raise SystemExit("No JSON object found in command output.")
obj = json.loads(raw[start:])
print(json.dumps(obj))'
}

json_get_scalar() {
  local json_input="$1"
  local dotted_path="$2"
  JSON_INPUT="$json_input" python3 - "$dotted_path" <<'PY'
import json
import os
import sys

value = json.loads(os.environ["JSON_INPUT"])
for part in sys.argv[1].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        raise SystemExit(f"Cannot read {sys.argv[1]} from non-object.")
if value is None:
    raise SystemExit(f"Missing value at {sys.argv[1]}")
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

run_models_status_json() {
  local raw
  raw="$("${DC[@]}" run --rm -T openclaw-cli models status --json 2>&1)"
  printf '%s' "$raw" | extract_json
}

validate_target_in_status() {
  local status_json="$1"
  local target="$2"
  JSON_INPUT="$status_json" python3 - "$target" <<'PY'
import json
import os
import sys

target = sys.argv[1]
data = json.loads(os.environ["JSON_INPUT"])
allowed = set(data.get("allowed", []))
if target not in allowed:
    raise SystemExit(
        "Target model is not in models status -> allowed. Rewire provider exposure first."
    )
print("allowed")
PY
}

sync_openclaw_defaults() {
  local target="$1"
  python3 - "$target" "$TEMPLATE_JSON" "$RUNTIME_JSON" <<'PY'
import json
import pathlib
import sys

target = sys.argv[1]
provider, model_id = target.split("/", 1)

for raw_path in sys.argv[2:]:
    path = pathlib.Path(raw_path)
    data = json.loads(path.read_text())

    aliases = (
        data.get("agents", {})
        .get("defaults", {})
        .get("models", {})
    )
    if target not in aliases:
        raise SystemExit(f"{path}: target {target} is missing from agents.defaults.models")

    if provider == "litellm":
        litellm_ids = {
            item.get("id")
            for item in (
                data.get("models", {})
                .get("providers", {})
                .get("litellm", {})
                .get("models", [])
            )
            if isinstance(item, dict)
        }
        if model_id not in litellm_ids:
            raise SystemExit(f"{path}: target {model_id} is missing from models.providers.litellm.models")

    data.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = target
    path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"synced {path}")
PY
}

describe_target_route() {
  if [[ "$TARGET_PROVIDER" != "litellm" ]]; then
    echo "${TARGET}: provider ${TARGET_PROVIDER} bypasses LiteLLM."
    return 0
  fi

  python3 - "$TARGET_MODEL" "$LITELLM_CONFIG" <<'PY'
import pathlib
import sys

target = sys.argv[1]
path = pathlib.Path(sys.argv[2])
lines = path.read_text().splitlines()
block = []
in_block = False

for line in lines:
    if line.startswith("  - model_name: "):
        current = line.split(":", 1)[1].strip()
        if in_block:
            break
        if current == target:
            in_block = True
        continue
    if in_block:
        block.append(line.strip())

if not block:
    print(f"{target}: alias not found in {path}")
    raise SystemExit(0)

data = {}
for line in block:
    if ":" not in line or line.startswith("#"):
        continue
    key, value = line.split(":", 1)
    data[key.strip()] = value.strip()

model = data.get("model", "unknown")
api_base = data.get("api_base", "")
api_key = data.get("api_key", "")

if "CLIPROXY_API_BASE" in api_base:
    route = "CLIProxyAPI/Codex OAuth"
elif "DANGLAMGIAU_API_BASE" in api_base:
    route = "DangLamGiau"
elif "CLAUDIBLE_API_BASE" in api_base:
    route = "Claudible"
elif model.startswith("minimax/"):
    route = "MiniMax direct"
elif model.startswith("openai/"):
    route = "OpenAI direct"
elif model.startswith("anthropic/"):
    route = "Anthropic direct"
else:
    route = "unknown"

parts = [f"alias={target}", f"upstream={model}", f"route={route}"]
if api_key:
    parts.append(f"credential={api_key}")
print(" | ".join(parts))
PY
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

backup_and_reset_main_session() {
  local backup_path
  backup_path="${SESSIONS_FILE}.bak-switch-$(date +%Y%m%d%H%M%S)"
  cp "$SESSIONS_FILE" "$backup_path"
  python3 - "$SESSIONS_FILE" <<'PY' >/dev/null
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
removed = data.pop("agent:main:main", None) is not None
path.write_text(json.dumps(data, indent=2) + "\n")
print("removed" if removed else "missing")
PY
  echo "$backup_path"
}

run_verify_session_json() {
  local verify_session_id="$1"
  local raw
  raw="$("${DC[@]}" run --rm -T openclaw-cli agent --session-id "$verify_session_id" --message 'Reply with exactly OK.' --json 2>&1)"
  printf '%s' "$raw" | extract_json
}

verify_session_matches_target() {
  local verify_json="$1"
  local target="$2"
  JSON_INPUT="$verify_json" python3 - "$target" <<'PY'
import json
import os
import sys

target_provider, target_model = sys.argv[1].split("/", 1)
data = json.loads(os.environ["JSON_INPUT"])

if data.get("status") != "ok":
    raise SystemExit(f"Verification command returned non-ok status: {data.get('status')}")

result = data.get("result", {})
meta = result.get("meta", {})
agent_meta = meta.get("agentMeta", {})
system_report = meta.get("systemPromptReport", {})

provider = system_report.get("provider") or agent_meta.get("provider")
model = system_report.get("model") or agent_meta.get("model")

output_text = []
for item in result.get("output", []):
    if item.get("type") == "message":
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                output_text.append(content.get("text", ""))

if provider != target_provider:
    raise SystemExit(f"Verification provider mismatch: expected {target_provider}, got {provider}")
if model != target_model:
    raise SystemExit(f"Verification model mismatch: expected {target_model}, got {model}")

reply = " ".join(part.strip() for part in output_text if part.strip())
print(f"verified_provider={provider}")
print(f"verified_model={model}")
if reply:
    print(f"reply={reply}")
PY
}

KEEP_MAIN_SESSION=0
SKIP_VERIFY=0
DRY_RUN=0

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TARGET="$(canonicalize_target "$1")"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-main-session)
      KEEP_MAIN_SESSION=1
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      ;;
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

require_cmd docker
require_cmd python3
require_cmd curl

ROOT="$(find_root)"
cd "$ROOT"

DC=(docker compose -f "$ROOT/docker-compose.yml")
TEMPLATE_JSON="$ROOT/config/openclaw.json"
RUNTIME_JSON="$ROOT/data/openclaw/config/openclaw.json"
SESSIONS_FILE="$ROOT/data/openclaw/config/agents/main/sessions/sessions.json"
LITELLM_CONFIG="$ROOT/config/litellm-config.yaml"

TARGET_PROVIDER="${TARGET%%/*}"
TARGET_MODEL="${TARGET#*/}"

if [[ ! -f "$SESSIONS_FILE" ]]; then
  echo "Missing sessions file: $SESSIONS_FILE" >&2
  exit 1
fi

set -a
. "$ROOT/.env"
set +a

OPENCLAW_BIND_HOST="${OPENCLAW_BIND_HOST:-127.0.0.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

CURRENT_STATUS_JSON="$(run_models_status_json)"
CURRENT_DEFAULT="$(json_get_scalar "$CURRENT_STATUS_JSON" "resolvedDefault")"

validate_target_in_status "$CURRENT_STATUS_JSON" "$TARGET" >/dev/null
ROUTE_SUMMARY="$(describe_target_route)"

echo "Stack root: $ROOT"
echo "Current selected model: $CURRENT_DEFAULT"
echo "Requested target model: $TARGET"
echo "Target route: $ROUTE_SUMMARY"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run only. No files or containers were changed."
  exit 0
fi

sync_openclaw_defaults "$TARGET"
"${DC[@]}" run --rm -T openclaw-cli models set "$TARGET"

UPDATED_STATUS_JSON="$(run_models_status_json)"
UPDATED_DEFAULT="$(json_get_scalar "$UPDATED_STATUS_JSON" "resolvedDefault")"
if [[ "$UPDATED_DEFAULT" != "$TARGET" ]]; then
  echo "models status did not resolve to the requested target. Expected $TARGET, got $UPDATED_DEFAULT" >&2
  exit 1
fi

"${DC[@]}" up -d --force-recreate openclaw-gateway
wait_for_http "http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz" 60 2

SESSION_BACKUP="not-created"
SESSION_RESET_RESULT="kept"
if [[ "$KEEP_MAIN_SESSION" -eq 0 ]]; then
  SESSION_BACKUP="$(backup_and_reset_main_session)"
  SESSION_RESET_RESULT="reset"
fi

VERIFY_RESULT="skipped"
if [[ "$SKIP_VERIFY" -eq 0 ]]; then
  VERIFY_SESSION_ID="model-switch-verify-$(date +%s)"
  VERIFY_JSON="$(run_verify_session_json "$VERIFY_SESSION_ID")"
  VERIFY_RESULT="$(verify_session_matches_target "$VERIFY_JSON" "$TARGET")"
fi

echo
echo "Switch complete."
echo "Selected model: $UPDATED_DEFAULT"
echo "Target route: $ROUTE_SUMMARY"
echo "Gateway ready: http://${OPENCLAW_BIND_HOST}:${OPENCLAW_GATEWAY_PORT}/readyz"
echo "Main session handling: $SESSION_RESET_RESULT"
echo "Session backup: $SESSION_BACKUP"
if [[ "$KEEP_MAIN_SESSION" -eq 0 ]]; then
  echo "Telegram DM context will start fresh on the next main-session message."
else
  echo "Telegram DM context was preserved. If the old model keeps appearing, rerun without --keep-main-session."
fi
echo "Verification:"
echo "$VERIFY_RESULT"
