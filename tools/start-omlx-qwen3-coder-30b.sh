#!/bin/bash
# Start the oMLX Qwen3-Coder candidate on a separate port for a controlled evaluation.
# It refuses to run while the Gemma pilot is still using port 8000, avoiding two loaded
# oMLX models competing for the Mac Studio's unified memory.
set -euo pipefail

MODEL_ROOT="${OMLX_CODING_MODEL_ROOT:-/Volumes/AiOS Repository/models/omlx}"
MODEL_REPO="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
MODEL_PATH="$MODEL_ROOT/$MODEL_REPO"
PORT="${OMLX_CODING_PORT:-18080}"
CACHE_DIR="${OMLX_CODING_CACHE_DIR:-$HOME/.omlx/cache-qwen3-coder-30b}"
SSD_CACHE_MAX_SIZE="${OMLX_CODING_SSD_CACHE_MAX_SIZE:-20GB}"
HOT_CACHE_MAX_SIZE="${OMLX_CODING_HOT_CACHE_MAX_SIZE:-8GB}"
OMLX_BIN="${OMLX_BIN:-$(command -v omlx || true)}"

if [ -z "$OMLX_BIN" ]; then
  echo "oMLX is not installed or is not on PATH." >&2
  exit 2
fi

if [ ! -f "$MODEL_PATH/config.json" ]; then
  echo "Qwen3-Coder model files are not present at: $MODEL_PATH" >&2
  echo "Download them first: bash tools/download-omlx-qwen3-coder-30b.sh" >&2
  exit 2
fi

if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "An oMLX server is still listening on port 8000 (the Gemma pilot)." >&2
  echo "Stop it with Control-C before loading Qwen3-Coder on this 64 GB Mac." >&2
  exit 2
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Choose another with OMLX_CODING_PORT=<port>." >&2
  exit 2
fi

mkdir -p "$CACHE_DIR"

echo "Starting oMLX Qwen3-Coder evaluation"
echo "  model root:    $MODEL_ROOT"
echo "  endpoint:      http://127.0.0.1:$PORT/v1"
echo "  SSD KV cache:  $CACHE_DIR (cap: $SSD_CACHE_MAX_SIZE)"
echo "  hot KV cache:  $HOT_CACHE_MAX_SIZE"
echo "  Ollama:        unchanged at http://127.0.0.1:11434/v1"
echo

exec "$OMLX_BIN" serve \
  --model-dir "$MODEL_ROOT" \
  --port "$PORT" \
  --memory-guard balanced \
  --paged-ssd-cache-dir "$CACHE_DIR" \
  --paged-ssd-cache-max-size "$SSD_CACHE_MAX_SIZE" \
  --hot-cache-max-size "$HOT_CACHE_MAX_SIZE"
