#!/usr/bin/env bash
# Overnight queue: processes all unchecked briefs in overnight-queue.md in sequence.
# Coder + reviewer servers start once and stay up for the whole run.
# Usage: ./tools/overnight-queue.sh [--queue <path-to-queue.md>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUEUE="${2:-$SCRIPT_DIR/overnight-queue.md}"
OUTDIR="/tmp/aios-overnight"
VENV="$HOME/.mlx-venv/bin/activate"

REVIEWER_MODEL="mlx-community/Devstral-Small-2505-4bit"
# 8080 = AiOS library port (brain-server, launchd-managed — never kill/start here)
# 8082 = Devstral reviewer (overnight only)
# The coder talks to whatever the library has loaded on :8080.
# Set EXECUTOR_MODEL to match whatever the library is serving.
CODER_PORT=8080
REVIEWER_PORT=8082
export EXECUTOR_MODEL="mlx-community/Qwen3.8-27B-4bit"
DEFAULT_WORKSPACE="/Volumes/AiOS Repository/code"

ORCHESTRATOR_PKG="/Volumes/AiOS Repository/code/AiOSOrchestrator"
export HF_HOME="/Volumes/AiOS Repository/mlx-models"

TODAY=$(date '+%Y-%m-%d')

mkdir -p "$OUTDIR"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUTDIR/queue.log"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -f "$QUEUE" ]]; then
    echo "ERROR: Queue file not found: $QUEUE" >&2; exit 1
fi

# Extract unchecked briefs from today's date section only
PENDING=()
while IFS= read -r _line; do
    PENDING+=("$_line")
done < <(python3 - "$QUEUE" "$TODAY" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
date = sys.argv[2]
match = re.search(rf'## {re.escape(date)}\n(.*?)(?=\n## |\Z)', text, re.DOTALL)
if match:
    for line in match.group(1).splitlines():
        if line.startswith('- [ ]'):
            print(line)
PY
)

if [[ ${#PENDING[@]} -eq 0 ]]; then
    log "No unchecked briefs for $TODAY in $QUEUE"
    osascript -e "display notification \"No briefs queued for $TODAY.\" with title \"AiOS Overnight Queue\""
    exit 0
fi
log "Found ${#PENDING[@]} brief(s) for $TODAY."

# ── Start reviewer only — coder is the always-on library server ───────────────
# :8080 = AiOS model library (launchd brain-server — never touch, always live)
# :8082 = Devstral reviewer (we manage this one)
log "=== Verifying library (:${CODER_PORT}) + starting reviewer (:${REVIEWER_PORT}) ==="

# Kill any stale reviewer on :8082, then wait for port to free
_pids=$(lsof -ti ":${REVIEWER_PORT}" 2>/dev/null || true)
if [[ -n "$_pids" ]]; then
    log "  killing stale reviewer PID(s) $_pids on :${REVIEWER_PORT}"
    echo "$_pids" | xargs kill -9 2>/dev/null || true
fi
for _w in $(seq 1 15); do
    _still=$(lsof -ti ":${REVIEWER_PORT}" 2>/dev/null || true)
    [[ -z "$_still" ]] && break
    [[ $_w -eq 15 ]] && { log "ERROR: Port ${REVIEWER_PORT} still in use after 15s."; exit 1; }
    sleep 1
done

# shellcheck source=/dev/null
source "$VENV"

REVIEWER_PATH="$HOME/Models/Devstral"
[[ ! -d "$REVIEWER_PATH" ]] && REVIEWER_PATH="$REVIEWER_MODEL"
nohup mlx_lm.server --model "$REVIEWER_PATH" --port "$REVIEWER_PORT" \
    > "$OUTDIR/reviewer-server.log" 2>&1 &
REVIEWER_PID=$!

log "Waiting for library (:${CODER_PORT}) + reviewer (:${REVIEWER_PORT})…"
for i in $(seq 1 120); do
    if ! kill -0 "$REVIEWER_PID" 2>/dev/null; then
        log "ERROR: Reviewer server exited early. Check $OUTDIR/reviewer-server.log"; exit 1
    fi
    coder_ok=false; reviewer_ok=false
    curl -sf "http://127.0.0.1:${CODER_PORT}/health" > /dev/null 2>&1 && coder_ok=true
    curl -sf "http://127.0.0.1:${REVIEWER_PORT}/health" > /dev/null 2>&1 && reviewer_ok=true
    if $coder_ok && $reviewer_ok; then log "Library + reviewer ready (${i} polls, $((i*5))s)."; break; fi
    if [[ $i -eq 120 ]]; then log "ERROR: Servers not ready after 10 min."; exit 1; fi
    sleep 5
done

# ── Process each brief ────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

for RAW_LINE in "${PENDING[@]}"; do
    # Parse "- [ ] <brief> [| <workspace>]"
    INNER="${RAW_LINE#- \[ \] }"
    if [[ "$INNER" == *" | "* ]]; then
        BRIEF="${INNER%% | *}"
        WORKSPACE="${INNER##* | }"
    else
        BRIEF="$INNER"
        WORKSPACE="$DEFAULT_WORKSPACE"
    fi
    BRIEF="${BRIEF%% *}"   # trim any trailing spaces/comments
    # Resolve relative paths against repo root
    [[ "$BRIEF" != /* ]] && BRIEF="$REPO_ROOT/$BRIEF"

    BRIEF_NAME="$(basename "${BRIEF%.md}")"
    BRIEF_OUTDIR="$OUTDIR/$BRIEF_NAME"
    mkdir -p "$BRIEF_OUTDIR"

    log ""
    log "━━━ Brief: $BRIEF_NAME ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ! -f "$BRIEF" ]]; then
        log "  ERROR: Brief not found at $BRIEF — skipping."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("SKIP  $BRIEF_NAME (file not found)")
        continue
    fi

    # Coding pass
    log "  Coding pass → coder output: $BRIEF_OUTDIR/coder-output.md"
    swift run --package-path "$ORCHESTRATOR_PKG" aios-orchestrate \
        "$(<"$BRIEF")" \
        --workspace "$WORKSPACE" \
        --apply \
        --executor-only \
        --executor-url "http://127.0.0.1:${CODER_PORT}" \
        --max-iterations 5 \
        > "$BRIEF_OUTDIR/coder-output.md" 2>&1 || true

    # Review
    if grep -qE "timed out|NSURLError|Error Domain" "$BRIEF_OUTDIR/coder-output.md" 2>/dev/null; then
        log "  WARNING: Coder failed for $BRIEF_NAME — skipping review."
        printf '## Review skipped\n\nCoder timed out or errored.\n' > "$BRIEF_OUTDIR/review.md"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("FAIL  $BRIEF_NAME (coder error)")
    else
        BRIEF_TEXT=$(<"$BRIEF")
        CODER_OUTPUT=$(<"$BRIEF_OUTDIR/coder-output.md")
        log "  Review pass → $BRIEF_OUTDIR/review.md"
        python3 - "$BRIEF_TEXT" "$CODER_OUTPUT" "$BRIEF_OUTDIR/review.md" <<'PY'
import json, pathlib, sys, urllib.request

brief, coder_output, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
prompt = f"""You are a senior Swift engineer doing a pre-commit code review.

=== BRIEF ===
{brief[:4000]}

=== GENERATED CODE ===
{coder_output[:8000]}

Check and flag specific issues:
1. Does the code fulfill every requirement in the brief?
2. Swift 6 actor isolation — missing await, wrong isolation?
3. Force unwraps in non-trivial positions?
4. Re-definitions of types the brief says exist in AiOSCore?
5. iOS-only APIs without #if os(iOS) or #available guards?
6. Any obvious compile errors?

First line: PASS or FAIL. Then bullet list of issues."""

payload = json.dumps({
    "model": "devstral",
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 800, "temperature": 0
}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:8082/v1/chat/completions",
    data=payload, headers={"Content-Type": "application/json"}, method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        content = json.loads(r.read())["choices"][0]["message"]["content"]
except Exception as e:
    content = f"## Review failed\n\n{e}"
pathlib.Path(out_path).write_text(content)
PY
        REVIEW_VERDICT=$(head -1 "$BRIEF_OUTDIR/review.md")
        log "  Review verdict: $REVIEW_VERDICT"
        if echo "$REVIEW_VERDICT" | grep -qi "^PASS"; then
            PASS_COUNT=$((PASS_COUNT + 1))
            RESULTS+=("PASS  $BRIEF_NAME")
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            RESULTS+=("FAIL  $BRIEF_NAME")
        fi
    fi

    # Mark done in checklist (replace "- [ ]" with "- [x]" + timestamp)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
    python3 - "$QUEUE" "$RAW_LINE" "$TIMESTAMP" <<'PY'
import pathlib, sys
queue_path, raw_line, ts = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(queue_path).read_text()
done_line = raw_line.replace("- [ ]", "- [x]", 1) + f"  ← {ts}"
text = text.replace(raw_line, done_line, 1)
pathlib.Path(queue_path).write_text(text)
PY
    log "  Marked done in $QUEUE"
done

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "=== QUEUE COMPLETE: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
for r in "${RESULTS[@]}"; do
    log "  $r"
done
log ""
log "Output dirs: $OUTDIR/<brief-name>/"
log "Open Xcode, select Claude agent, and run the gate on each PASS result."

SUMMARY=$(printf '%s\n' "${RESULTS[@]}" | sed 's/^/  /')
osascript -e "display notification \"${PASS_COUNT} passed, ${FAIL_COUNT} failed. Open Xcode for gate.\" with title \"AiOS Overnight Queue Done\""
