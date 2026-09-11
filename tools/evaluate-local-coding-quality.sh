#!/bin/bash
# Produce a source-grounded, no-edit coding-quality report for one local OpenAI-compatible model.
# Run it serially: first against oMLX Qwen3-Coder, then after stopping that server against Ollama.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${MODEL_BASE_URL:?Set MODEL_BASE_URL, for example http://127.0.0.1:18080/v1}"
MODEL="${MODEL_ID:?Set MODEL_ID to the exact value from /v1/models}"
LABEL="${1:-local-model}"
MAX_TOKENS="${LOCAL_MODEL_EVAL_MAX_TOKENS:-160}"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs '[:alnum:]._- ' '_' | tr ' ' '_')"
OUT_DIR="${LOCAL_MODEL_EVAL_DIR:-$REPO/context/Perplexity notes/local-model-evaluations}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/${STAMP}-${SAFE_LABEL}.md"
PAYLOAD_ARCH="$(mktemp /tmp/local-model-architecture.XXXXXX.json)"
PAYLOAD_PATCH="$(mktemp /tmp/local-model-patch.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/local-model-response.XXXXXX.json)"
trap 'rm -f "$PAYLOAD_ARCH" "$PAYLOAD_PATCH" "$RESPONSE"' EXIT

if ! curl --silent --show-error --fail "$BASE_URL/models" >/dev/null; then
  echo "Model endpoint is not responding at $BASE_URL" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

python3 - "$REPO" "$MODEL" "$PAYLOAD_ARCH" "$PAYLOAD_PATCH" "$MAX_TOKENS" <<'PY'
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
model = sys.argv[2]
architecture_path = pathlib.Path(sys.argv[3])
patch_path = pathlib.Path(sys.argv[4])
max_tokens = int(sys.argv[5])
parts = []
for relative in ["AGENTS.md", "LOCALAGENT.md"]:
    path = repo / relative
    if path.exists():
        parts.append(f"\n--- {relative} ---\n{path.read_text(errors='replace')[:9000]}")
for path in sorted((repo / "AiOSCore" / "Sources").rglob("*.swift"))[:12]:
    parts.append(f"\n--- {path.relative_to(repo)} ---\n{path.read_text(errors='replace')[:6000]}")
context = "".join(parts)
system = (
    "You are evaluating a local coding model against a real Swift repository. "
    "Use only the supplied context. Do not claim to inspect unprovided files. "
    "Do not modify files or run commands. Be specific, concise, and state uncertainty plainly."
)
architecture_prompt = (
    "Architecture-review task. From the supplied AiOS context, identify exactly three concrete "
    "architectural invariants. For each, cite a supplied file and relevant type, protocol, or symbol. "
    "Then name one focused test target and explain why it protects an invariant. Do not invent code.\n"
    + context
)
patch_prompt = (
    "Bounded patch-design task. From the supplied AiOS context, identify one low-risk improvement "
    "to correctness or test coverage that is supported by direct evidence. Return: (1) evidence with "
    "file/symbol references, (2) a minimal unified diff proposal that is clearly marked PROPOSED ONLY, "
    "and (3) the most focused verification command. If there is insufficient evidence for a safe diff, "
    "say so instead of inventing one. Do not apply a change.\n"
    + context
)
def payload(prompt):
    return {
        "model": model,
        "temperature": 0,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
    }
architecture_path.write_text(json.dumps(payload(architecture_prompt)))
patch_path.write_text(json.dumps(payload(patch_prompt)))
print(f"Prepared {len(context):,} characters of fixed repository context.")
PY

cat >"$REPORT" <<EOF_REPORT
# Local Coding-Model Evaluation: $LABEL

- Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')
- Endpoint: $BASE_URL
- Model: $MODEL
- Mode: source-grounded, no source edits, temperature 0\n- Response budget: $MAX_TOKENS tokens per task

EOF_REPORT

run_case() {
  local title="$1" payload="$2" start end elapsed content
  start="$(python3 -c 'import time; print(time.perf_counter())')"
  local attempt=1
  while ! curl --silent --show-error --fail \
    -H 'Content-Type: application/json' \
    --data @"$payload" \
    "$BASE_URL/chat/completions" >"$RESPONSE"; do
    if [ "$attempt" -ge 2 ]; then
      echo "${title} failed after ${attempt} attempts." >&2
      return 1
    fi
    attempt=$((attempt + 1))
    echo "${title} request interrupted; retrying once." >&2
    sleep 2
  done
  end="$(python3 -c 'import time; print(time.perf_counter())')"
  elapsed="$(python3 - "$start" "$end" <<'PY'
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")
PY
)"
  content="$(python3 - "$RESPONSE" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
print(body["choices"][0]["message"]["content"])
PY
)"
  {
    printf '## %s\n\n' "$title"
    printf -- '- Elapsed: %ss\n\n' "$elapsed"
    printf '```text\n%s\n```\n\n' "$content"
  } >>"$REPORT"
  printf '%s: %ss\n' "$title" "$elapsed"
}

echo "== Local coding-quality evaluation: $LABEL =="
run_case "Architecture review" "$PAYLOAD_ARCH"
run_case "Bounded patch design" "$PAYLOAD_PATCH"
echo
echo "Report written: $REPORT"
