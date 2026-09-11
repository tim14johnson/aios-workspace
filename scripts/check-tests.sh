#!/bin/bash
# Test-execution check. AGENTS.md's "definition of done" requires tests to actually be run,
# not assumed passing.
#
# Usage: scripts/check-tests.sh <core|hub|business|myfamily|all>

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

log_info "Using repository Xcode toolchain: $DEVELOPER_DIR"

FAIL=0

test_core() {
  log_header "Tests: AiOSCore (swift test)"
  if ( cd "$AIOS_ROOT/AiOSCore" && "$AIOS_SWIFT" test ); then
    log_pass "AiOSCore: tests passed"
  else
    log_fail "AiOSCore: tests failed"
    FAIL=1
  fi
}

test_app() {
  local target="$1" scheme; scheme="$(target_scheme "$target")"
  log_header "Tests: $scheme (xcodebuild test)"
  if ( cd "$AIOS_ROOT" && "$AIOS_XCODEBUILD" -workspace AiOS.xcworkspace -scheme "$scheme" \
        -destination 'platform=macOS' test ); then
    log_pass "$scheme: tests passed"
  else
    log_fail "$scheme: tests failed"
    FAIL=1
  fi
}

targets="$(resolve_targets "${1:-all}")" || exit 2
while IFS= read -r t; do
  case "$t" in
    core) test_core ;;
    hub|business|myfamily) test_app "$t" ;;
  esac
done <<< "$targets"

exit "$FAIL"
