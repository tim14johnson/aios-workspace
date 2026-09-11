#!/bin/bash
# Start oMLX beside Ollama for the AiOS local-model pilot.
# It intentionally reuses existing MLX models and uses port 8000, leaving Ollama's
# port 11434, model store, and configuration unchanged.
set -euo pipefail

MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/.lmstudio/models}"
PORT="${OMLX_PORT:-8000}"
CACHE_DIR="${OMLX_CACHE_DIR:-$HOME/.omlx/cache}"
SSD_CACHE_MAX_SIZE="${OMLX_SSD_CACHE_MAX_SIZE:-20GB}"
HOT_CACHE_MAX_SIZE="${OMLX_HOT_CACHE_MAX_SIZE:-8GB}"
OMLX_BIN="${OMLX_BIN:-$(command -v omlx || true)}"

if [ -z "$OMLX_BIN" ]; then
  cat >&2 <<'MSG'
oMLX is not installed or is not on PATH.

Install it from a normal local Terminal, not through a remote-control session.

This Mac has Xcode 27 beta at `/Applications/Xcode-beta-b4.app`. Homebrew otherwise
sees the older Xcode.app, so install with this scoped command:
  DEVELOPER_DIR="/Applications/Xcode-beta-b4.app/Contents/Developer" brew install omlx

The oMLX tap and formula trust should already be present. Do not repeat them.
If Homebrew reports an ownership problem, stop and run `brew doctor` in that same
local Terminal. Do not use a broad sudo/chown command just to force this pilot through.
MSG
  exit 2
fi

if [ ! -d "$MODEL_DIR" ]; then
  echo "MLX model directory not found: $MODEL_DIR" >&2
  exit 2
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Choose another port with OMLX_PORT=<port>." >&2
  exit 2
fi

if ! mkdir -p "$CACHE_DIR"; then
  echo "Cannot create oMLX cache directory: $CACHE_DIR" >&2
  exit 2
fi

echo "Starting oMLX pilot"
echo "  model directory: $MODEL_DIR"
echo "  endpoint:        http://127.0.0.1:$PORT/v1"
echo "  SSD KV cache:    $CACHE_DIR (cap: $SSD_CACHE_MAX_SIZE)"
echo "  hot KV cache:    $HOT_CACHE_MAX_SIZE"
echo "  Ollama remains:  http://127.0.0.1:11434/v1"
echo
exec "$OMLX_BIN" serve \
  --model-dir "$MODEL_DIR" \
  --port "$PORT" \
  --paged-ssd-cache-dir "$CACHE_DIR" \
  --paged-ssd-cache-max-size "$SSD_CACHE_MAX_SIZE" \
  --hot-cache-max-size "$HOT_CACHE_MAX_SIZE"
