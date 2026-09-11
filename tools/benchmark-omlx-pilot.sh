#!/bin/bash
# Compare the first and repeated oMLX turn against the same repository-grounded prompt.
# Run only after tools/start-omlx-pilot.sh has started oMLX in another Terminal window.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${OMLX_BASE_URL:-http://127.0.0.1:8000/v1}"
MODEL="${1:-gemma-4-E4B-it-MLX-4bit}"
PAYLOAD="$(mktemp /tmp/omlx-pilot-payload.XXXXXX.json)"
FIRST="$(mktemp /tmp/omlx-pilot-first.XXXXXX.json)"
SECOND="$(mktemp /tmp/omlx-pilot-second.XXXXXX.json)"
trap 'rm -f "$PAYLOAD" "$FIRST" "$SECOND"' EXIT

if ! curl --silent --show-error --fail "$BASE_URL/models" >/dev/null; then
  echo "oMLX is not responding at $BASE_URL. Start the pilot first:" >&2
  echo "  bash tools/start-omlx-pilot.sh" >&2
  exit 2
fi

python3 - "$REPO" "$MODEL" "$PAYLOAD" <<'PY'
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
model = sys.argv[2]
out = pathlib.Path(sys.argv[3])
parts = []
for relative in ["AGENTS.md", "LOCALAGENT.md"]:
    path = repo / relative
    if path.exists():
        parts.append(f"\n--- {relative} ---\n{path.read_text(errors='replace')}")
for path in sorted((repo / "AiOSCore" / "Sources").rglob("*.swift"))[:12]:
    parts.append(f"\n--- {path.relative_to(repo)} ---\n{path.read_text(errors='replace')[:6000]}")
context = "".join(parts)
payload = {
    "model": model,
    "temperature": 0,
    "max_tokens": 180,
    "messages": [
        {"role": "system", "content": "You are a local code-review assistant. Respond concisely and do not invent files."},
        {"role": "user", "content": "Review the following AiOS project context. Name three concrete architectural invariants and one focused test target.\n" + context},
    ],
}
out.write_text(json.dumps(payload))
print(f"Prepared {len(context):,} characters of fixed repository context.")
PY

run_turn() {
  local label="$1" output="$2" start end elapsed preview
  start="$(python3 -c 'import time; print(time.perf_counter())')"
  curl --silent --show-error --fail \
    -H 'Content-Type: application/json' \
    --data @"$PAYLOAD" \
    "$BASE_URL/chat/completions" >"$output"
  end="$(python3 -c 'import time; print(time.perf_counter())')"
  elapsed="$(python3 - "$start" "$end" <<'PY'
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")
PY
)"
  preview="$(python3 - "$output" <<'PY'
import json, sys
try:
    content = json.load(open(sys.argv[1]))["choices"][0]["message"]["content"]
    print(" ".join(content.split())[:300])
except Exception as exc:
    print(f"Could not parse response: {exc}")
PY
)"
  echo "$label: ${elapsed}s"
  echo "  $preview"
}

echo "== oMLX repeated-context pilot =="
echo "Endpoint: $BASE_URL"
echo "Model:    $MODEL"
run_turn "First turn" "$FIRST"
run_turn "Repeated identical turn" "$SECOND"
echo
echo "Interpretation: the second turn should normally be meaningfully faster if oMLX reuses the prompt/KV cache."
echo "This benchmark does not alter Ollama, OpenCode, Xcode, model files, or repository source."
