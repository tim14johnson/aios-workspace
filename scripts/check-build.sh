#!/bin/bash
# Build-cleanliness check. AGENTS.md's "definition of done" requires a clean build with
# zero new warnings — this fails on ANY warning, since the project has none today and the
# simplest way to keep it that way is to never let one land.
#
# Usage: scripts/check-build.sh <core|hub|business|myfamily|all>

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

log_info "Using repository Xcode toolchain: $DEVELOPER_DIR"

FAIL=0

build_core() {
  log_header "Build: AiOSCore (swift build)"
  local log; log="$(mktemp)"
  ( cd "$AIOS_ROOT/AiOSCore" && "$AIOS_SWIFT" build 2>&1 ) | tee "$log"
  local status="${PIPESTATUS[0]}"
  local warnings; warnings="$(grep -c 'warning:' "$log" || true)"
  if [ "$status" -ne 0 ]; then
    log_fail "AiOSCore: build failed"
    FAIL=1
  elif [ "${warnings:-0}" -gt 0 ]; then
    log_fail "AiOSCore: build succeeded with $warnings warning(s)"
    FAIL=1
  else
    log_pass "AiOSCore: clean build, 0 warnings"
  fi
  rm -f "$log"
}

build_app() {
  local target="$1" scheme; scheme="$(target_scheme "$target")"
  log_header "Build: $scheme (xcodebuild)"
  local log; log="$(mktemp)"
  ( cd "$AIOS_ROOT" && "$AIOS_XCODEBUILD" -workspace AiOS.xcworkspace -scheme "$scheme" \
      -destination 'platform=macOS' build 2>&1 ) | tee "$log"
  local status="${PIPESTATUS[0]}"
  local warnings; warnings="$(grep -c ': warning:' "$log" || true)"
  if [ "$status" -ne 0 ]; then
    log_fail "$scheme: build failed"
    FAIL=1
  elif [ "${warnings:-0}" -gt 0 ]; then
    log_fail "$scheme: build succeeded with $warnings warning(s)"
    FAIL=1
  else
    log_pass "$scheme: clean build, 0 warnings"
  fi
  rm -f "$log"
}

targets="$(resolve_targets "${1:-all}")" || exit 2
while IFS= read -r t; do
  case "$t" in
    core) build_core ;;
    hub|business|myfamily) build_app "$t" ;;
  esac
done <<< "$targets"

exit "$FAIL"
