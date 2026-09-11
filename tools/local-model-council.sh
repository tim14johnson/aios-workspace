#!/bin/bash
# Run a local proposer, critic, and adjudicator without copying responses between apps.
# This command never edits project source. It only writes a timestamped review report.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  tools/local-model-council.sh "<task or question>" <source-file> [<source-file> ...]

Example:
  tools/local-model-council.sh \
    "Plan a minimal change to tighten this permission rule. Do not edit." \
    AiOSCore/Sources/AiOSCore/AccessControl.swift \
    AiOSCore/Tests/AiOSCoreTests/AccessControlTests.swift

Environment overrides:
  COUNCIL_PRIMARY_MODEL       default: qwen3-coder:30b
  COUNCIL_CRITIC_MODEL        default: devstral-small-2:24b
  COUNCIL_JUDGE_MODEL         default: qwen3-coder:30b
  COUNCIL_*_BASE_URL          default: http://127.0.0.1:11434/v1
  COUNCIL_MAX_SOURCE_CHARS    default: 60000
  COUNCIL_MAX_TOKENS          default: 550
  COUNCIL_LABEL               default: local-model-council
  COUNCIL_UNLOAD_FINAL        default: 1 (unload final Ollama model after the report)
USAGE
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

REQUEST="$1"
shift

PRIMARY_BASE_URL="${COUNCIL_PRIMARY_BASE_URL:-http://127.0.0.1:11434/v1}"
PRIMARY_MODEL="${COUNCIL_PRIMARY_MODEL:-qwen3-coder:30b}"
CRITIC_BASE_URL="${COUNCIL_CRITIC_BASE_URL:-http://127.0.0.1:11434/v1}"
CRITIC_MODEL="${COUNCIL_CRITIC_MODEL:-devstral-small-2:24b}"
JUDGE_BASE_URL="${COUNCIL_JUDGE_BASE_URL:-http://127.0.0.1:11434/v1}"
JUDGE_MODEL="${COUNCIL_JUDGE_MODEL:-qwen3-coder:30b}"
MAX_SOURCE_CHARS="${COUNCIL_MAX_SOURCE_CHARS:-60000}"
MAX_TOKENS="${COUNCIL_MAX_TOKENS:-550}"
UNLOAD_FINAL="${COUNCIL_UNLOAD_FINAL:-1}"
ALLOW_MIXED_ENDPOINTS="${COUNCIL_ALLOW_MIXED_ENDPOINTS:-0}"
LABEL="${COUNCIL_LABEL:-local-model-council}"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs '[:alnum:]._- ' '_' | tr ' ' '_')"
OUT_DIR="${LOCAL_MODEL_COUNCIL_DIR:-$REPO/context/Perplexity notes/local-model-council}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/${STAMP}-${SAFE_LABEL}.md"

SOURCE_BUNDLE="$(mktemp /tmp/local-model-council-source.XXXXXX)"
PRIMARY_OUTPUT="$(mktemp /tmp/local-model-council-primary.XXXXXX)"
CRITIC_OUTPUT="$(mktemp /tmp/local-model-council-critic.XXXXXX)"
JUDGE_OUTPUT="$(mktemp /tmp/local-model-council-judge.XXXXXX)"
ROLE_PROMPT="$(mktemp /tmp/local-model-council-prompt.XXXXXX)"
PAYLOAD="$(mktemp /tmp/local-model-council-payload.XXXXXX.json)"
RESPONSE="$(mktemp /tmp/local-model-council-response.XXXXXX.json)"
trap 'rm -f "$SOURCE_BUNDLE" "$PRIMARY_OUTPUT" "$CRITIC_OUTPUT" "$JUDGE_OUTPUT" "$ROLE_PROMPT" "$PAYLOAD" "$RESPONSE"' EXIT

python3 - "$REPO" "$MAX_SOURCE_CHARS" "$SOURCE_BUNDLE" "$@" <<'PY'
import pathlib
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
limit = int(sys.argv[2])
out = pathlib.Path(sys.argv[3])
arguments = sys.argv[4:]
parts = []
total = 0

for argument in arguments:
    path = pathlib.Path(argument)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    try:
        relative = path.relative_to(repo)
    except ValueError:
        raise SystemExit(f"Source file must be inside the repository: {path}")
    if not path.is_file():
        raise SystemExit(f"Source file not found: {relative}")
    content = path.read_text(errors="replace")
    total += len(content)
    if total > limit:
        raise SystemExit(
            f"Selected source is {total:,} characters, over the {limit:,} character limit. "
            "Use fewer or more focused files; do not silently truncate context."
        )
    parts.append(f"===== FILE: {relative} =====\n{content}\n")

out.write_text("\n".join(parts))
print(f"Prepared {len(arguments)} complete source file(s): {total:,} characters.")
PY

mkdir -p "$OUT_DIR"

if { [ "$PRIMARY_BASE_URL" != "$CRITIC_BASE_URL" ] || [ "$PRIMARY_BASE_URL" != "$JUDGE_BASE_URL" ]; } && [ "$ALLOW_MIXED_ENDPOINTS" != "1" ]; then
  echo "Refusing mixed model endpoints by default. Run all roles through one local runtime, or explicitly set COUNCIL_ALLOW_MIXED_ENDPOINTS=1 after manually confirming that only one large model is resident at a time." >&2
  exit 2
fi

check_model_available() {
  local base_url="$1"
  local model="$2"
  local inventory
  inventory="$(mktemp /tmp/local-model-council-models.XXXXXX.json)"

  if ! curl --silent --show-error --fail "$base_url/models" >"$inventory"; then
    rm -f "$inventory"
    echo "Model endpoint is not responding at $base_url" >&2
    exit 2
  fi
  if ! python3 - "$inventory" "$model" <<'PY'
import json
import pathlib
import sys

models = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("data", [])
if not any(item.get("id") == sys.argv[2] for item in models):
    raise SystemExit(1)
PY
  then
    rm -f "$inventory"
    echo "Model $model is not available at $base_url. Choose an installed local model before running the council." >&2
    exit 2
  fi
  rm -f "$inventory"
}

# Verify every requested role before beginning a multi-step review.
check_model_available "$PRIMARY_BASE_URL" "$PRIMARY_MODEL"
check_model_available "$CRITIC_BASE_URL" "$CRITIC_MODEL"
check_model_available "$JUDGE_BASE_URL" "$JUDGE_MODEL"

write_role_prompt() {
  local role="$1"
  python3 - "$role" "$REQUEST" "$SOURCE_BUNDLE" "$PRIMARY_OUTPUT" "$CRITIC_OUTPUT" "$ROLE_PROMPT" <<'PY'
import pathlib
import sys

role, request, source_path, primary_path, critic_path, out_path = sys.argv[1:]
source = pathlib.Path(source_path).read_text()
primary = pathlib.Path(primary_path).read_text() if pathlib.Path(primary_path).stat().st_size else "(not yet available)"
critic = pathlib.Path(critic_path).read_text() if pathlib.Path(critic_path).stat().st_size else "(not yet available)"

common = f"""Task from the developer:\n{request}\n\nComplete, bounded source evidence:\n{source}\n"""
if role == "proposer":
    prompt = f"""You are the PROPOSER in a local coding council. Work only from the supplied files. Do not edit files and do not invent omitted code. Produce a narrow, testable plan, not an implementation.\n\n{common}\nReturn exactly these headings:\nPROPOSAL\nEVIDENCE\nRISKS\nVERIFICATION\n"""
elif role == "critic":
    prompt = f"""You are the independent CRITIC in a local coding council. Falsify the proposer where warranted. Work only from the supplied files. Do not edit files and do not assume that confident wording is proof.\n\n{common}\nProposer response:\n{primary}\n\nReturn exactly these headings:\nCRITIQUE: ACCEPT, REJECT, or NEEDS_EVIDENCE\nCONFIRMED_EVIDENCE\nUNSUPPORTED_OR_MISSED_CLAIMS\nREQUIRED_VERIFICATION\n"""
else:
    prompt = f"""You are the ADJUDICATOR in a local coding council. Decide from the complete source evidence and the two earlier reviews. Do not edit files. Reject claims that are not supported by an exact file symbol or text present in the supplied evidence. If the evidence is insufficient, choose ESCALATE rather than guessing.\n\n{common}\nProposer response:\n{primary}\n\nCritic response:\n{critic}\n\nReturn exactly these headings:\nDECISION: PROCEED, REVISE, or ESCALATE\nAPPROVED_PLAN\nEVIDENCE_TO_VERIFY\nREJECTED_CLAIMS\nTEST_COMMANDS\n"""

pathlib.Path(out_path).write_text(prompt)
PY
}

run_role() {
  local role="$1"
  local base_url="$2"
  local model="$3"
  local output="$4"
  local start end

  write_role_prompt "$role"
  python3 - "$model" "$MAX_TOKENS" "$ROLE_PROMPT" "$PAYLOAD" <<'PY'
import json
import pathlib
import sys

model, max_tokens, prompt_path, payload_path = sys.argv[1:]
payload = {
    "model": model,
    "temperature": 0,
    "max_tokens": int(max_tokens),
    "messages": [
        {
            "role": "system",
            "content": "You are a careful local code-review specialist. Use only supplied source. Never claim to have edited, built, or tested anything you did not receive evidence for.",
        },
        {"role": "user", "content": pathlib.Path(prompt_path).read_text()},
    ],
}
pathlib.Path(payload_path).write_text(json.dumps(payload))
PY

  start="$(python3 -c 'import time; print(time.perf_counter())')"
  local attempt=1
  while ! curl --silent --show-error --fail \
    -H 'Content-Type: application/json' \
    --data @"$PAYLOAD" \
    "$base_url/chat/completions" >"$RESPONSE"; do
    if [ "$attempt" -ge 2 ]; then
      echo "$role request failed after ${attempt} attempts." >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    echo "$role request interrupted; retrying once." >&2
    sleep 2
  done
  end="$(python3 -c 'import time; print(time.perf_counter())')"
  ROLE_ELAPSED="$(python3 - "$start" "$end" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.2f}")
PY
)"
  python3 - "$RESPONSE" "$output" <<'PY'
import json
import pathlib
import sys
response = json.loads(pathlib.Path(sys.argv[1]).read_text())
content = response["choices"][0]["message"]["content"]
pathlib.Path(sys.argv[2]).write_text(content)
PY
}

unload_ollama_if_applicable() {
  local base_url="$1"
  local model="$2"
  case "$base_url" in
    http://127.0.0.1:11434/v1|http://localhost:11434/v1)
      if command -v ollama >/dev/null 2>&1; then
        ollama stop "$model" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

printf '== Local model council ==\n'
printf 'Proposer:    %s (%s)\n' "$PRIMARY_MODEL" "$PRIMARY_BASE_URL"
printf 'Critic:      %s (%s)\n' "$CRITIC_MODEL" "$CRITIC_BASE_URL"
printf 'Adjudicator: %s (%s)\n' "$JUDGE_MODEL" "$JUDGE_BASE_URL"

run_role "proposer" "$PRIMARY_BASE_URL" "$PRIMARY_MODEL" "$PRIMARY_OUTPUT"
PRIMARY_ELAPSED="$ROLE_ELAPSED"
unload_ollama_if_applicable "$PRIMARY_BASE_URL" "$PRIMARY_MODEL"

run_role "critic" "$CRITIC_BASE_URL" "$CRITIC_MODEL" "$CRITIC_OUTPUT"
CRITIC_ELAPSED="$ROLE_ELAPSED"
unload_ollama_if_applicable "$CRITIC_BASE_URL" "$CRITIC_MODEL"

run_role "adjudicator" "$JUDGE_BASE_URL" "$JUDGE_MODEL" "$JUDGE_OUTPUT"
JUDGE_ELAPSED="$ROLE_ELAPSED"
if [ "$UNLOAD_FINAL" = "1" ]; then
  unload_ollama_if_applicable "$JUDGE_BASE_URL" "$JUDGE_MODEL"
fi

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
{
  printf '# Local Model Council: %s\n\n' "$LABEL"
  printf -- '- Timestamp: %s\n' "$timestamp"
  printf -- '- This command made no source-code edits; it created this review record only.\n'
  printf -- '- Task: %s\n\n' "$REQUEST"
  printf '## Roles\n\n'
  printf -- '- **Proposer:** `%s` at `%s` (%ss)\n' "$PRIMARY_MODEL" "$PRIMARY_BASE_URL" "$PRIMARY_ELAPSED"
  printf -- '- **Critic:** `%s` at `%s` (%ss)\n' "$CRITIC_MODEL" "$CRITIC_BASE_URL" "$CRITIC_ELAPSED"
  printf -- '- **Adjudicator:** `%s` at `%s` (%ss)\n\n' "$JUDGE_MODEL" "$JUDGE_BASE_URL" "$JUDGE_ELAPSED"
  printf '## Proposer\n\n```text\n'
  cat "$PRIMARY_OUTPUT"
  printf '\n```\n\n## Critic\n\n```text\n'
  cat "$CRITIC_OUTPUT"
  printf '\n```\n\n## Adjudicator\n\n```text\n'
  cat "$JUDGE_OUTPUT"
  printf '\n```\n'
} >"$REPORT"

printf 'Proposer: %ss\nCritic: %ss\nAdjudicator: %ss\n' "$PRIMARY_ELAPSED" "$CRITIC_ELAPSED" "$JUDGE_ELAPSED"
printf 'Council report written: %s\n' "$REPORT"
