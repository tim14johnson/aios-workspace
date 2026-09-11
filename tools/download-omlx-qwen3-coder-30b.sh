#!/bin/bash
# Download the dedicated MLX Qwen3-Coder candidate to the AiOS external SSD.
# This is intentionally separate from Ollama and is resumable if interrupted.
set -euo pipefail

MODEL_REPO="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
MODEL_ROOT="${OMLX_CODING_MODEL_ROOT:-/Volumes/AiOS Repository/models/omlx}"
MODEL_PATH="$MODEL_ROOT/$MODEL_REPO"
VOLUME="/Volumes/AiOS Repository"
HF_BIN="${HF_BIN:-/opt/homebrew/opt/omlx/libexec/bin/hf}"
MIN_FREE_GIB="${OMLX_MIN_FREE_GIB:-25}"
WORKERS="${HF_MAX_WORKERS:-4}"

if [ ! -d "$VOLUME" ]; then
  echo "AiOS external volume is not mounted: $VOLUME" >&2
  exit 2
fi

if [ ! -x "$HF_BIN" ]; then
  echo "oMLX-managed Hugging Face CLI was not found: $HF_BIN" >&2
  exit 2
fi

available_kib="$(df -Pk "$VOLUME" | awk 'NR == 2 { print $4 }')"
required_kib=$((MIN_FREE_GIB * 1024 * 1024))
if [ -z "$available_kib" ] || [ "$available_kib" -lt "$required_kib" ]; then
  echo "At least ${MIN_FREE_GIB} GiB must be free on $VOLUME before downloading." >&2
  exit 2
fi

mkdir -p "$MODEL_ROOT"

echo "Downloading the oMLX coding-model candidate"
echo "  repository: $MODEL_REPO"
echo "  destination: $MODEL_PATH"
echo "  expected footprint: approximately 17.21 GB"
echo "  workers: $WORKERS"
echo
echo "The Hugging Face client resumes partial downloads by default."
echo

"$HF_BIN" download "$MODEL_REPO" \
  --local-dir "$MODEL_PATH" \
  --max-workers "$WORKERS"

for required_file in config.json tokenizer.json; do
  if [ ! -f "$MODEL_PATH/$required_file" ]; then
    echo "Expected model file is missing after download: $required_file" >&2
    exit 2
  fi
done

if ! find "$MODEL_PATH" -maxdepth 1 -name '*.safetensors' -print -quit | grep -q .; then
  echo "No safetensors weight files were found after download." >&2
  exit 2
fi

echo
echo "Download verification passed."
echo "  stored size: $(du -sh "$MODEL_PATH" | awk '{print $1}')"
echo "Next: stop the Gemma oMLX pilot, then run:"
echo "  bash tools/start-omlx-qwen3-coder-30b.sh"
