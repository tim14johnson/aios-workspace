#!/usr/bin/env bash
# Overnight coding pipeline: Qwen 27B (coder) → Devstral (reviewer)
# Usage: ./tools/overnight-code.sh <brief.md> [--workspace <path>]
#
# ── Large-model coder slot (future) ─────────────────────────────────────────
# Swap Qwen 27B for a larger model by changing CODER_MODEL and CODER_PORT.
# Candidate tested: Flash-Next 180B GGUF via llama-server — DOES NOT WORK on
# 64GB Mac Studio. CPU decode = 0.18 tok/s; GPU path bus-errors despite
# iogpu.wired_limit_mb=60416 (Metal OOM or bad -ot regex, TBD).
# Model files preserved at ~/Models/UD-IQ4_XS/ if you want to retry later.
#
# Better candidates that should work on 64GB MLX:
#   mlx-community/Qwen3-72B-4bit          (~40 GB, best quality upgrade)
#   mlx-community/Qwen2.5-Coder-32B-Instruct-4bit  (~18 GB, code-specialist)
#   mlx-community/Qwen3-30B-A3B-4bit      (~16 GB, MoE — fast decode)
# To switch: change CODER_MODEL below and keep CODER_PORT=8080.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BRIEF="${1:?Usage: $0 <brief-file> [--workspace <path>]}"
WORKSPACE="${3:-/Volumes/AiOS Repository/code/AiOSCore}"
OUTDIR="/tmp/aios-overnight"
VENV="$HOME/.mlx-venv/bin/activate"

CODER_MODEL="mlx-community/Qwen3.8-27B-4bit"
REVIEWER_MODEL="mlx-community/Devstral-Small-2505-4bit"
CODER_PORT=8080
REVIEWER_PORT=8082

export HF_HOME="/Volumes/AiOS Repository/mlx-models"
ORCHESTRATOR_PKG="/Volumes/AiOS Repository/code/AiOSOrchestrator"

mkdir -p "$OUTDIR"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUTDIR/pipeline.log"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -f "$BRIEF" ]]; then
    echo "ERROR: Brief file not found: $BRIEF" >&2
    exit 1
fi

# ── 1. Start coder + reviewer ─────────────────────────────────────────────────
log "=== STEP 1: Starting Qwen (coder :${CODER_PORT}) + Devstral (reviewer :${REVIEWER_PORT}) ==="
for _port in "$CODER_PORT" "$REVIEWER_PORT"; do
    _pids=$(lsof -ti ":$_port" 2>/dev/null || true)
    if [[ -n "$_pids" ]]; then
        log "  killing PID(s) $_pids on :$_port"
        echo "$_pids" | xargs kill -9 2>/dev/null || true
    fi
done
sleep 2

# shellcheck source=/dev/null
source "$VENV"
nohup mlx_lm.server --model "$CODER_MODEL" --port "$CODER_PORT" \
    > "$OUTDIR/coder-server.log" 2>&1 &
CODER_PID=$!
nohup mlx_lm.server --model "$REVIEWER_MODEL" --port "$REVIEWER_PORT" \
    > "$OUTDIR/reviewer-server.log" 2>&1 &
REVIEWER_PID=$!

log "Waiting for both servers (up to 10 min)…"
for i in $(seq 1 120); do
    if ! kill -0 "$CODER_PID" 2>/dev/null; then
        log "ERROR: Coder server (PID $CODER_PID) exited early."
        tail -10 "$OUTDIR/coder-server.log" | tee -a "$OUTDIR/pipeline.log"
        exit 1
    fi
    coder_ok=false; reviewer_ok=false
    curl -sf "http://127.0.0.1:${CODER_PORT}/health" > /dev/null 2>&1 && coder_ok=true
    curl -sf "http://127.0.0.1:${REVIEWER_PORT}/health" > /dev/null 2>&1 && reviewer_ok=true
    if $coder_ok && $reviewer_ok; then log "Both servers ready (${i} polls, $((i*5))s)."; break; fi
    if [[ $i -eq 120 ]]; then
        log "ERROR: Servers not ready after 10 min. Check coder-server.log / reviewer-server.log."
        exit 1
    fi
    sleep 5
done

# ── 2. Coder pass ─────────────────────────────────────────────────────────────
log "=== STEP 2: Qwen coding pass ==="
swift run --package-path "$ORCHESTRATOR_PKG" aios-orchestrate \
    "$(<"$BRIEF")" \
    --workspace "$WORKSPACE" \
    --apply \
    --executor-only \
    --executor-url "http://127.0.0.1:${CODER_PORT}" \
    --max-iterations 5 \
    > "$OUTDIR/coder-output.md" 2>&1 || true
log "Coding pass complete. Output: $OUTDIR/coder-output.md"

# ── 3. Review — guard against error output first ──────────────────────────────
log "=== STEP 3: Review ==="
PIPELINE_STATUS="ok"
if grep -qE "timed out|NSURLError|Error Domain" "$OUTDIR/coder-output.md" 2>/dev/null; then
    log "WARNING: Coder output contains an error — skipping review."
    printf '## Review skipped\n\nCoding pass failed (timeout or HTTP error).\nSee: %s\n' \
        "$OUTDIR/coder-server.log" > "$OUTDIR/review.md"
    PIPELINE_STATUS="no-output"
else
    BRIEF_TEXT=$(<"$BRIEF")
    CODER_OUTPUT=$(<"$OUTDIR/coder-output.md")
    python3 - "$BRIEF_TEXT" "$CODER_OUTPUT" "$OUTDIR/review.md" <<'PY'
import json, pathlib, sys, urllib.request

brief, coder_output, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

prompt = f"""You are a senior Swift engineer doing a pre-commit code review.
Qwen 27B generated code from this brief. Review it for issues.

=== BRIEF ===
{brief[:4000]}

=== GENERATED CODE ===
{coder_output[:8000]}

Check each item and flag specific line-level issues:
1. Does the code fulfill every requirement stated in the brief?
2. Swift 6 actor isolation — missing `await`, wrong isolation, nonisolated access?
3. Force unwraps (`!`) in non-trivial positions?
4. Re-definitions of types the brief says already exist in AiOSCore?
5. iOS-only APIs without `#if os(iOS)` or `#available` guards?
6. Any other obvious compile errors?

Respond with PASS or FAIL on the first line, then a bullet list of specific issues."""

payload = json.dumps({
    "model": "devstral",
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 800,
    "temperature": 0
}).encode()
req = urllib.request.Request(
    f"http://127.0.0.1:8082/v1/chat/completions",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        data = json.loads(r.read())
        content = data["choices"][0]["message"]["content"]
except Exception as e:
    content = f"## Review failed\n\nDevstral unreachable: {e}"
pathlib.Path(out_path).write_text(content)
print(content[:300])
PY
    log "Review complete. Output: $OUTDIR/review.md"
fi

# ── 4. Ready for Claude gate ──────────────────────────────────────────────────
log "=== STEP 4: READY FOR CLAUDE REVIEW ==="
log ""
log "  Brief:       $BRIEF"
log "  Coder out:   $OUTDIR/coder-output.md"
log "  Review:      $OUTDIR/review.md"
log "  Full log:    $OUTDIR/pipeline.log"
log ""
if [[ "$PIPELINE_STATUS" == "no-output" ]]; then
    log "  Coder failed — split the brief or check coder-server.log."
    osascript -e "display notification \"Coder failed — no output. Check pipeline.log.\" with title \"AiOS Overnight Pipeline ⚠️\""
else
    log "Open Xcode, select Claude agent, and run the final gate."
    osascript -e "display notification \"Qwen coding + Devstral review done. Open Xcode for Claude gate.\" with title \"AiOS Overnight Pipeline\""
fi
