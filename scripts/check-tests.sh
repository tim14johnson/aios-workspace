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

  # UI tests (XCUITest) require Accessibility permission granted to the test runner process.
  # In headless environments (CI, SSH session, locked screen) the process can't get that
  # permission and the suite hangs. Skip UI tests automatically when CI=true, or when
  # AIOS_SKIP_UI_TESTS=1 is set manually. Set AIOS_RUN_UI_TESTS=1 to force them on.
  local skip_ui=0
  if [ "${AIOS_RUN_UI_TESTS:-0}" = "1" ]; then
    skip_ui=0
  elif [ "${CI:-}" = "true" ] || [ "${AIOS_SKIP_UI_TESTS:-0}" = "1" ]; then
    skip_ui=1
  fi

  local skip_args=()
  if [ "$skip_ui" -eq 1 ]; then
    skip_args=(-skip-testing "${scheme}UITests")
    log_warn "$scheme: UI tests skipped (headless/CI — set AIOS_RUN_UI_TESTS=1 to force)"
  fi

  # macOS ships bash 3.2, where "${arr[@]}" on an empty array throws "unbound variable" under
  # `set -u` — the "${arr[@]+"${arr[@]}"}" form is the portable way to expand a possibly-empty
  # array under nounset on that old a bash.
  if ( cd "$AIOS_ROOT" && "$AIOS_XCODEBUILD" -workspace AiOS.xcworkspace -scheme "$scheme" \
        -destination 'platform=macOS' test "${skip_args[@]+"${skip_args[@]}"}" ); then
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
