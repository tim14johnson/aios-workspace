#!/bin/bash
# Test whether a local model grounds its conclusion in a complete Swift source file.
# This is a no-edit evaluation. It records one model's verdict for later comparison.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${MODEL_BASE_URL:?Set MODEL_BASE_URL, for example http://127.0.0.1:18080/v1}"
MODEL="${MODEL_ID:?Set MODEL_ID to the exact value from /v1/models}"
LABEL="${1:-local-model}"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs '[:alnum:]._- ' '_' | tr ' ' '_')"
SOURCE="$REPO/AiOSCore/Sources/AiOSCore/AccessControl.swift"
OUT_DIR="${LOCAL_MODEL_EVAL_DIR:-$REPO/context/Perplexity notes/local-model-evaluations}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/${STAMP}-${SAFE_LABEL}-access-control-grounding.md"
PAYLOAD="$(mktemp /tmp/access-control-grounding.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/access-control-response.XXXXXX.json)"
trap 'rm -f "$PAYLOAD" "$RESPONSE"' EXIT

if [ ! -f "$SOURCE" ]; then
  echo "Expected source file not found: $SOURCE" >&2
  exit 2
fi

if ! curl --silent --show-error --fail "$BASE_URL/models" >/dev/null; then
  echo "Model endpoint is not responding at $BASE_URL" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

python3 - "$SOURCE" "$MODEL" "$PAYLOAD" <<'PY'
import json
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
model = sys.argv[2]
out = pathlib.Path(sys.argv[3])
content = source.read_text(errors='replace')
prompt = """You are reviewing one COMPLETE Swift source file. Use only this full file.

A prior assistant claimed that PermissionEvaluator.access(_:) fails to handle a user with no matching grants and needs a new `var level = AccessLevel.none` fallback. Is that claim correct?

Return exactly:
1. VERDICT: TRUE or FALSE
2. Two exact evidence citations in the format `AccessControl.swift:<line-or-symbol> — <reason>`
3. PATCH: either `NO PATCH` or a minimal proposed unified diff.

Do not infer omitted code. Do not modify files.

--- COMPLETE AccessControl.swift ---
""" + content
payload = {
  "model": model,
  "temperature": 0,
  "max_tokens": 180,
  "messages": [
    {"role": "system", "content": "You are a precise Swift code reviewer. Never invent missing source."},
    {"role": "user", "content": prompt},
  ],
}
out.write_text(json.dumps(payload))
print(f"Prepared complete source file: {len(content):,} characters.")
PY

start="$(python3 -c 'import time; print(time.perf_counter())')"
attempt=1
while ! curl --silent --show-error --fail \
  -H 'Content-Type: application/json' \
  --data @"$PAYLOAD" \
  "$BASE_URL/chat/completions" >"$RESPONSE"; do
  if [ "$attempt" -ge 2 ]; then
    echo "Grounding request failed after ${attempt} attempts." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo "Request interrupted; retrying once." >&2
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
print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"])
PY
)"
timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

{
  printf '# Access-Control Grounding Test: %s\n\n' "$LABEL"
  printf -- '- Timestamp: %s\n' "$timestamp"
  printf -- '- Endpoint: %s\n' "$BASE_URL"
  printf -- '- Model: %s\n' "$MODEL"
  printf -- '- Source: `AiOSCore/Sources/AiOSCore/AccessControl.swift` supplied in full\n'
  printf -- '- Elapsed: %ss\n\n' "$elapsed"
  printf '```text\n%s\n```\n' "$content"
} >"$REPORT"

echo "Grounding test: ${elapsed}s"
echo "Report written: $REPORT"
