#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env in $ROOT_DIR"
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: ./scripts/claude-code.sh <claude args...>"
  echo "Examples:"
  echo "  ./scripts/claude-code.sh auth login"
  echo "  ./scripts/claude-code.sh auth status"
  echo "  ./scripts/claude-code.sh --help"
  exit 1
fi

mkdir -p ./data/openclaw/claude

exec docker compose exec openclaw-gateway claude "$@"
