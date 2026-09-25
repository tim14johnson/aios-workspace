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

# ── Model library ports ───────────────────────────────────────────────────────
# FUTURE: orchestrator/distributor pulls the right model from the library for
# each job type (coding, review, reasoning, embedding…) and checks it back in.
# Models may run on MLX or llama.cpp; each gets its own stable port so jobs can
# run concurrently without competing for RAM.
#
# TODAY: a single library server handles both coding and review passes.
# The review prompt goes to the same port as the coder — one model in RAM.
# Replace REVIEW_URL below once the multi-port library is wired.
CODER_PORT=8080
REVIEW_URL="http://127.0.0.1:${CODER_PORT}"  # same server until library routing exists
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

# ── Check the model out of the library ────────────────────────────────────────
# :8080 = AiOS model library (launchd brain-server, on demand). Hold a lease for the whole run so
# the Hub's idle timer can't offload the model between briefs; it's released on exit.
# Both coding and review passes share this model until multi-model routing lands.
# shellcheck source=lib/brain-lease.sh
source "$SCRIPT_DIR/lib/brain-lease.sh"

# shellcheck source=/dev/null
source "$VENV"

log "=== Checking out ${EXECUTOR_MODEL} from the library (:${CODER_PORT}) ==="
if ! brain_lease_acquire "$EXECUTOR_MODEL" "Overnight queue" 900; then
    log "ERROR: ${EXECUTOR_MODEL} not serving after 15 min."
    exit 1
fi
log "Library serving ${EXECUTOR_MODEL}."

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
        python3 - "$BRIEF_TEXT" "$CODER_OUTPUT" "$BRIEF_OUTDIR/review.md" "$REVIEW_URL" <<'PY'
import json, pathlib, sys, urllib.request

brief, coder_output, out_path, review_url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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
    "model": "default",  # library serves whatever is loaded; replace with model ID when routing lands
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": 800, "temperature": 0
}).encode()
req = urllib.request.Request(
    f"{review_url}/v1/chat/completions",
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
