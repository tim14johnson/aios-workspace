#!/bin/bash
# One-time setup: points each of the 4 AiOS sub-repos' git hooks at the shared githooks/
# directory at the workspace root (via `git config core.hooksPath`), so pre-commit/pre-push
# enforcement is defined once and shared across repos instead of duplicated 4x.
#
# Run once, from anywhere:
#   scripts/install-git-hooks.sh
#
# Undo for a single repo:
#   git -C AiOSHub config --unset core.hooksPath
#
# Bypass on a single commit/push without uninstalling:
#   git commit --no-verify
#   git push --no-verify

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

chmod +x "$AIOS_ROOT/githooks/pre-commit" "$AIOS_ROOT/githooks/pre-push"
chmod +x "$SCRIPT_DIR"/*.sh

for repo in "${AIOS_ALL_REPOS[@]}"; do
  dir="$AIOS_ROOT/$repo"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" config core.hooksPath ../githooks
    log_pass "$repo: core.hooksPath -> ../githooks"
  else
    log_warn "$repo: not a git repo yet, skipped"
  fi
done

log_info ""
log_info "Done. Hooks are now active:"
log_info "  pre-commit — fast hygiene checks on staged files (scripts/check-hygiene.sh --staged)"
log_info "  pre-push   — full verify for the repo being pushed (scripts/verify.sh <target>)"
