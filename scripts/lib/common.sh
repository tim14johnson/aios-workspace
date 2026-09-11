#!/bin/bash
# Shared helpers for AiOS repo-hygiene/build/test scripts.
# Sourced by other scripts/*.sh — not meant to be run directly.

# Resolve the workspace root (parent of scripts/) regardless of the caller's cwd.
AIOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The independently-versioned git repos inside the AiOS workspace.
AIOS_APP_TARGETS=(AiOSHub AiOSBusiness AiOSMyFamily)
AIOS_ALL_REPOS=(AiOSCore AiOSHub AiOSBusiness AiOSMyFamily)

if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

log_info()   { printf '%s\n' "$*"; }
log_pass()   { printf '%s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
log_fail()   { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET"; }
log_warn()   { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
log_header() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RESET"; }

# Pin build and test work to the compatible Xcode 27 toolchain without changing
# the machine-wide xcode-select setting.
# shellcheck source=toolchain.sh
source "$(dirname "${BASH_SOURCE[0]}")/toolchain.sh"

# resolve_targets <arg> -> echoes one target name per line (core/hub/business/myfamily)
resolve_targets() {
  case "${1:-all}" in
    all) printf 'core\nhub\nbusiness\nmyfamily\n' ;;
    core|hub|business|myfamily) printf '%s\n' "$1" ;;
    *) echo "Unknown target: $1 (expected core|hub|business|myfamily|all)" >&2; return 2 ;;
  esac
}

target_repo_dir() {
  case "$1" in
    core) echo "$AIOS_ROOT/AiOSCore" ;;
    hub) echo "$AIOS_ROOT/AiOSHub" ;;
    business) echo "$AIOS_ROOT/AiOSBusiness" ;;
    myfamily) echo "$AIOS_ROOT/AiOSMyFamily" ;;
  esac
}

target_scheme() {
  case "$1" in
    hub) echo "AiOSHub" ;;
    business) echo "AiOSBusiness" ;;
    myfamily) echo "AiOSMyFamily" ;;
  esac
}
