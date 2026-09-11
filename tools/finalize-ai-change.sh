#!/bin/bash
# Commit only after the Claude + Perplexity senior gate passes on the current staged diff.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  SENIOR_COUNCIL_SEND=1 bash tools/finalize-ai-change.sh \
    --repo AiOSCore \
    --message "Describe the verified change" \
    [--blueprint path/to/senior-blueprint.md]

This command re-runs the senior gate against the CURRENT staged diff. It commits only when every
configured senior reviewer returns VERDICT: PASS. It never stages additional files.
USAGE
}

GIT_REPO=""
MESSAGE=""
BLUEPRINT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) GIT_REPO="${2:-}"; shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --blueprint) BLUEPRINT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$GIT_REPO" ] && [ -n "$MESSAGE" ] || { usage >&2; exit 2; }
case "$GIT_REPO" in
  /*) ;;
  *) GIT_REPO="$REPO_ROOT/$GIT_REPO" ;;
esac
[ -d "$GIT_REPO/.git" ] || { echo "Not a Git repository: $GIT_REPO" >&2; exit 2; }

gate_args=(gate --repo "$GIT_REPO")
if [ -n "$BLUEPRINT" ]; then
  gate_args+=(--blueprint "$BLUEPRINT")
fi

python3 "$REPO_ROOT/tools/senior-council.py" "${gate_args[@]}"

git -C "$GIT_REPO" diff --cached --quiet && { echo "Gate passed but no staged diff remains; nothing committed." >&2; exit 2; }
git -C "$GIT_REPO" commit -m "$MESSAGE"
echo "Committed only after the senior council passed the staged diff."
