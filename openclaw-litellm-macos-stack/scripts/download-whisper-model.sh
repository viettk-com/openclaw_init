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

ensure_cmd docker

if [[ -f .env ]]; then
  set -a
  . ./.env
  set +a
fi

MODEL_NAME="${1:-${WHISPER_CPP_MODEL_NAME:-base}}"
IMAGE="${WHISPER_CPP_LOCAL_IMAGE:-openclaw-whispercpp-local:latest}"
WHISPER_CPP_REF="${WHISPER_CPP_REF:-}"
WHISPER_CPP_CPU_ARM_ARCH="${WHISPER_CPP_CPU_ARM_ARCH:-armv8.2-a+fp16}"
MODEL_DIR="${ROOT_DIR}/data/whisper/models"

mkdir -p "$MODEL_DIR"

echo "Building local whisper.cpp image '${IMAGE}'"
docker build \
  -f "${ROOT_DIR}/docker/whispercpp.Dockerfile" \
  -t "${IMAGE}" \
  --build-arg "WHISPER_CPP_REF=${WHISPER_CPP_REF}" \
  --build-arg "GGML_CPU_ARM_ARCH=${WHISPER_CPP_CPU_ARM_ARCH}" \
  "${ROOT_DIR}"

echo
echo "Downloading whisper.cpp model '${MODEL_NAME}' into ${MODEL_DIR}"
docker run --rm \
  -v "${MODEL_DIR}:/models" \
  -e MODEL_NAME="${MODEL_NAME}" \
  "${IMAGE}" \
  /bin/sh -lc '
    set -e
    if [ -x ./models/download-ggml-model.sh ]; then
      exec ./models/download-ggml-model.sh "${MODEL_NAME}" /models
    fi
    if [ -x /app/models/download-ggml-model.sh ]; then
      exec /app/models/download-ggml-model.sh "${MODEL_NAME}" /models
    fi
    echo "Could not locate download-ggml-model.sh inside image ${0}" >&2
    exit 1
  '

echo
echo "Download completed. Files in ${MODEL_DIR}:"
ls -1 "$MODEL_DIR"
