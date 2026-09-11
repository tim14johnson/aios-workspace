#!/bin/bash
# One-command "definition of done" check per AGENTS.md: hygiene is clean, the target(s)
# build with zero warnings, and relevant tests pass. This is the single entrypoint a future
# CI job (or you, before saying "done") should call.
#
# Usage:
#   scripts/verify.sh              # everything: hygiene + all 4 targets
#   scripts/verify.sh core         # just AiOSCore — fast, no simulator needed
#   scripts/verify.sh hub|business|myfamily

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TARGET="${1:-all}"
OVERALL=0

"$SCRIPT_DIR/check-hygiene.sh" || OVERALL=1
"$SCRIPT_DIR/check-build.sh" "$TARGET" || OVERALL=1
"$SCRIPT_DIR/check-tests.sh" "$TARGET" || OVERALL=1

log_header "Summary"
if [ "$OVERALL" -eq 0 ]; then
  log_pass "All checks passed for target: $TARGET"
else
  log_fail "One or more checks failed for target: $TARGET"
fi
exit "$OVERALL"
