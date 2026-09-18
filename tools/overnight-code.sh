#!/usr/bin/env bash
# Usage: ./tools/overnight-code.sh <path-to-brief.md> [--workspace <repo-path>]
# Runs the full Flash-Next (GGUF/llama-server) → Qwen+Devstral review loop, unattended.
# Flash-Next uses true MoE expert offloading: active experts in RAM, inactive evicted via mmap.

set -euo pipefail

BRIEF="${1:?Usage: $0 <brief-file> [--workspace <path>]}"
WORKSPACE="${3:-/Volumes/AiOS Repository/code/AiOSCore}"
OUTDIR="/tmp/aios-overnight"
VENV="$HOME/.mlx-venv/bin/activate"
QWEN_MODEL="mlx-community/Qwen3.8-27B-4bit"
DEVSTRAL_MODEL="mlx-community/Devstral-Small-2505-4bit"
FLASH_PORT=8090   # dedicated port; avoids the Hub app's Qwen MLX server on :8080

# Model files on external — main model + MTP speculative draft
FLASH_MODEL=$(ls "/Volumes/AiOS Repository/ollama/UD-IQ4_XS/"*-00001-of-*.gguf 2>/dev/null | head -1)
MTP_DRAFT="/Volumes/AiOS Repository/ollama/MTP/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"

# Keep HuggingFace cache on external so any model downloads skip internal storage
export HF_HOME="/Volumes/AiOS Repository/mlx-models"

ORCHESTRATOR_PKG="/Volumes/AiOS Repository/code/AiOSOrchestrator"
COUNCIL_SCRIPT="/Volumes/AiOS Repository/code/tools/local-model-council.sh"

mkdir -p "$OUTDIR"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUTDIR/pipeline.log"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -f "$BRIEF" ]]; then
    echo "ERROR: Brief file not found: $BRIEF" >&2
    exit 1
fi
if [[ -z "$FLASH_MODEL" ]]; then
    log "ERROR: No UD-IQ4_XS GGUF found in /Volumes/AiOS Repository/ollama/UD-IQ4_XS/"
    log "Download it first: hf download unsloth/Qwen3.8-Flash-Next-GGUF --include 'UD-IQ4_XS/*' --local-dir '/Volumes/AiOS Repository/ollama'"
    exit 1
fi
log "Flash-Next model: $FLASH_MODEL"
[[ -f "$MTP_DRAFT" ]] && log "MTP draft: $MTP_DRAFT" || log "MTP draft not found — running without speculative decoding"

# ── 1. Switch to Evening Mode ─────────────────────────────────────────────────
log "=== STEP 1: Evening Mode (Flash-Next 180B via llama-server) ==="
# Kill by port — more robust than process-name matching; catches mlx_lm.server
# regardless of how it was invoked (python -m, venv, tmux, etc.).
log "Clearing ports 8080, 8082, and ${FLASH_PORT}..."
for _port in 8080 8082 "$FLASH_PORT"; do
    _pids=$(lsof -ti ":$_port" 2>/dev/null || true)
    if [[ -n "$_pids" ]]; then
        log "  killing PID(s) $_pids on :$_port"
        echo "$_pids" | xargs kill -9 2>/dev/null || true
    fi
done
sleep 3

# CPU-only (-ngl 0): GPU offloading (-ngl 99 + -ot expert routing) causes a Bus error on
# 64GB Mac because Metal wired buffer allocation for 180B attention layers exceeds the
# default iogpu.wired_limit_mb. To enable GPU, run this ONCE before the script:
#   sudo sysctl -w iogpu.wired_limit_mb=60416
# and change -ngl 0 to -ngl 99 and add: -ot "blk\..+\.ffn_(gate|down|up)_exps=CPU"
# MTP spec-draft disabled — mtp-*.gguf is incompatible with this llama.cpp build.
# -np 1: single parallel slot — avoids 4× KV cache multiplication of -c value.
nohup llama-server \
    -m "$FLASH_MODEL" \
    --load-mode mmap \
    -ngl 0 \
    --cache-type-k q4_0 --cache-type-v q4_0 \
    -c 8192 -np 1 --port "$FLASH_PORT" \
    > "$OUTDIR/flash-next-server.log" 2>&1 &
FLASH_PID=$!
log "Flash-Next starting on :$FLASH_PORT (PID $FLASH_PID). Waiting for /health (up to 20 min for first load)…"

# Poll until server responds — 240 × 5s = 20 minutes
for i in $(seq 1 240); do
    # Liveness guard: if llama-server exited (port conflict, bad model path, etc.)
    # don't waste 20 minutes polling — bail immediately with a useful log tail.
    if ! kill -0 "$FLASH_PID" 2>/dev/null; then
        log "ERROR: llama-server (PID $FLASH_PID) exited early — port conflict or bad model path."
        tail -20 "$OUTDIR/flash-next-server.log" | tee -a "$OUTDIR/pipeline.log"
        exit 1
    fi
    if curl -sf "http://127.0.0.1:$FLASH_PORT/health" > /dev/null 2>&1; then
        log "Flash-Next ready (${i} polls, $((i * 5))s)."
        break
    fi
    if [[ $i -eq 240 ]]; then
        log "ERROR: Flash-Next did not respond after 20 minutes. Check $OUTDIR/flash-next-server.log"
        exit 1
    fi
    sleep 5
done

# ── 2. Flash-Next codes the brief ─────────────────────────────────────────────
log "=== STEP 2: Flash-Next coding pass ==="
swift run --package-path "$ORCHESTRATOR_PKG" aios-orchestrate \
    "$(<"$BRIEF")" \
    --workspace "$WORKSPACE" \
    --apply \
    --executor-only \
    --executor-url "http://127.0.0.1:$FLASH_PORT" \
    --max-iterations 5 \
    > "$OUTDIR/flash-next-output.md" 2>&1 || true
log "Flash-Next coding pass complete. Output: $OUTDIR/flash-next-output.md"

# ── 3. Auto-swap to Morning Mode ──────────────────────────────────────────────
log "=== STEP 3: Restoring Qwen + Devstral for review ==="
kill "$FLASH_PID" 2>/dev/null || true
for _port in 8080 8082; do
    _pids=$(lsof -ti ":$_port" 2>/dev/null || true)
    [[ -n "$_pids" ]] && echo "$_pids" | xargs kill -9 2>/dev/null || true
done
sleep 2

# shellcheck source=/dev/null
source "$VENV"
nohup mlx_lm.server --model "$QWEN_MODEL" --port 8080 \
    > "$OUTDIR/qwen-server.log" 2>&1 &
sleep 10
nohup mlx_lm.server --model "$DEVSTRAL_MODEL" --port 8082 \
    > "$OUTDIR/devstral-server.log" 2>&1 &

log "Waiting for Qwen + Devstral (up to 2 min)…"
for i in $(seq 1 24); do
    qwen_ok=false; devstral_ok=false
    curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1 && qwen_ok=true
    curl -sf http://127.0.0.1:8082/health > /dev/null 2>&1 && devstral_ok=true
    if $qwen_ok && $devstral_ok; then log "Both servers ready."; break; fi
    sleep 5
done

# ── 4. Qwen + Devstral review ─────────────────────────────────────────────────
log "=== STEP 4: Qwen + Devstral review ==="
DIFF=$(git -C "$WORKSPACE" diff --staged 2>/dev/null || git -C "$WORKSPACE" diff HEAD 2>/dev/null || echo "(no diff)")
bash "$COUNCIL_SCRIPT" \
    "Review this diff for correctness, security, and test coverage. Be a skeptic." \
    "$DIFF" \
    > "$OUTDIR/review.md" 2>&1 || true
log "Review complete. Output: $OUTDIR/review.md"

# ── 5. Ready for Claude gate ──────────────────────────────────────────────────
log "=== STEP 5: READY FOR CLAUDE REVIEW ==="
log ""
log "  Brief:          $BRIEF"
log "  Flash-Next out: $OUTDIR/flash-next-output.md"
log "  Review:         $OUTDIR/review.md"
log "  Full log:       $OUTDIR/pipeline.log"
log ""
log "Open AiOS Hub → System Health to see current state."
log "Open Xcode, select Claude agent, and run the final gate."

osascript -e "display notification \"Flash-Next + review done. Open Xcode for Claude gate.\" with title \"AiOS Overnight Pipeline\""
