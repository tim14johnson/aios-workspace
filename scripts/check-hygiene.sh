#!/bin/bash
# Repo hygiene checks for the AiOS workspace.
# Dependency-free, grep/git-based checks that catch common hygiene mistakes and a few
# AGENTS.md-specific rules. These are heuristics, not a linter — some hits are false
# positives; the point is to make you look, not to be a strict gate.
#
# Checks:
#   - tracked .DS_Store files / build artifacts (.build, DerivedData) per sub-repo
#   - missing .gitignore per sub-repo
#   - merge-conflict markers in Swift files
#   - `import Combine` (AGENTS.md rule 2: Swift Concurrency only)
#   - force-unwrap / try! / as! outside test files (AGENTS.md rule 1) — advisory
#   - literal "The Part Works" / "TPW" strings outside docs/ or context/ (AGENTS.md rule 6)
#   - undeclared third-party SwiftPM dependencies (AGENTS.md rule 5) vs.
#     scripts/allowed-dependencies.txt
#
# Usage:
#   scripts/check-hygiene.sh              # scan all 4 sub-repos (tracked files)
#   scripts/check-hygiene.sh --staged     # scan only files staged in the CURRENT repo
#                                          # (used by the shared pre-commit hook)
#
# Exit code: 0 if clean, 1 if any check fails.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FAIL=0

grep_hits() {
  # $1 = pattern (extended regex), remaining args = files. Prints any matches, indented.
  local pattern="$1"; shift
  [ "$#" -eq 0 ] && return 1
  grep -InE "$pattern" -- "$@" 2>/dev/null
}

check_swift_patterns() {
  # $1 = label prefix, $2.. = swift files (may be empty)
  local label="$1"; shift
  local files=("$@")
  [ "${#files[@]}" -eq 0 ] && return 0

  local hits
  hits=$(grep_hits '^[[:space:]]*(<<<<<<<|=======|>>>>>>>)' "${files[@]}")
  if [ -n "$hits" ]; then
    log_fail "$label: merge-conflict markers"
    printf '%s\n' "$hits" | sed 's/^/    /'
    FAIL=1
  fi

  hits=$(grep_hits '^[[:space:]]*import[[:space:]]+Combine' "${files[@]}")
  if [ -n "$hits" ]; then
    log_fail "$label: import Combine (AGENTS.md requires async/await, no Combine)"
    printf '%s\n' "$hits" | sed 's/^/    /'
    FAIL=1
  fi

  # Force-unwrap / try! / as! outside test files — advisory only.
  local non_test=()
  for f in "${files[@]}"; do
    case "$f" in
      *Tests/*|*Tests.swift) continue ;;
      *) non_test+=("$f") ;;
    esac
  done
  if [ "${#non_test[@]}" -gt 0 ]; then
    hits=$(grep_hits '[]A-Za-z0-9_)][!]([^=]|$)' "${non_test[@]}")
    if [ -n "$hits" ]; then
      log_warn "$label: possible force-unwrap/try!/as! outside test files — review (AGENTS.md rule 1)"
      printf '%s\n' "$hits" | sed 's/^/    /'
    fi
  fi
}

check_proprietary_data() {
  # $1.. = files not under docs/ or context/
  local files=("$@")
  [ "${#files[@]}" -eq 0 ] && return 0
  local hits
  # Rule 6 targets TPW's *proprietary business data*, NOT Tim's own employment history.
  # "The Part Works" as an employer in résumé fixtures is his factual career record and is
  # allowed; we still flag "TPW "-style tokens that tend to accompany business data (meeting
  # names, CRM/deal identifiers). See AGENTS.md rule 6 / work-mac-and-ip.
  hits=$(grep_hits 'TPW[_ -]' "${files[@]}")
  if [ -n "$hits" ]; then
    log_fail "Possible hardcoded TPW business data outside docs//context/ (AGENTS.md rule 6)"
    printf '%s\n' "$hits" | sed 's/^/    /'
    FAIL=1
  fi
}

check_dependencies() {
  log_header "Third-party dependency allowlist"
  local allowlist="$AIOS_ROOT/scripts/allowed-dependencies.txt"
  local found=()
  local url

  for repo in "${AIOS_ALL_REPOS[@]}"; do
    local dir="$AIOS_ROOT/$repo"
    [ -d "$dir" ] || continue

    if [ -f "$dir/Package.swift" ]; then
      while IFS= read -r url; do
        [ -n "$url" ] && found+=("$url")
      done < <(grep -oE '\.package\([^)]*url:[[:space:]]*"[^"]+"' "$dir/Package.swift" 2>/dev/null \
                 | sed -E 's/.*url:[[:space:]]*"([^"]+)".*/\1/')
    fi

    while IFS= read -r pbx; do
      while IFS= read -r url; do
        [ -n "$url" ] && found+=("$url")
      done < <(grep -oE 'repositoryURL = "[^"]+"' "$pbx" 2>/dev/null \
                 | sed -E 's/.*"([^"]+)".*/\1/')
    done < <(find "$dir" -iname "project.pbxproj" -not -path "*/.git/*" 2>/dev/null)
  done

  if [ "${#found[@]}" -eq 0 ]; then
    log_pass "No third-party SwiftPM dependencies found (matches current baseline)"
    return
  fi

  local seen=()
  for url in "${found[@]}"; do
    case " ${seen[*]:-} " in *" $url "*) continue ;; esac
    seen+=("$url")
    if [ -f "$allowlist" ] && grep -qF "$url" "$allowlist"; then
      log_pass "Allowed dependency: $url"
    else
      log_fail "Undeclared dependency: $url"
      log_info "    Add a one-line justification to scripts/allowed-dependencies.txt (AGENTS.md rule 5) once approved."
      FAIL=1
    fi
  done
}

run_staged_mode() {
  local repo_name
  repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
  log_header "Hygiene (staged files in $repo_name)"

  local staged=()
  while IFS= read -r f; do
    [ -n "$f" ] && staged+=("$f")
  done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

  if [ "${#staged[@]}" -eq 0 ]; then
    log_pass "No staged files"
    return
  fi

  for f in "${staged[@]}"; do
    case "$f" in
      *.DS_Store)
        log_fail "Staged .DS_Store file: $f"; FAIL=1 ;;
    esac
    if [ -f "$f" ]; then
      local size
      size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
      if [ "$size" -gt 5242880 ]; then
        log_fail "Staged file over 5MB: $f ($((size / 1024 / 1024))MB) — is this meant to be committed?"
        FAIL=1
      fi
    fi
  done

  local swift_files=() non_docs_files=()
  for f in "${staged[@]}"; do
    [ -f "$f" ] || continue
    case "$f" in *.swift) swift_files+=("$f") ;; esac
    case "$f" in docs/*|context/*|*/docs/*|*/context/*) ;; *) non_docs_files+=("$f") ;; esac
  done

  check_swift_patterns "Staged" ${swift_files[@]+"${swift_files[@]}"}
  check_proprietary_data ${non_docs_files[@]+"${non_docs_files[@]}"}

  if [ "$FAIL" -eq 0 ]; then
    log_pass "Staged hygiene checks passed"
  fi
}

run_full_mode() {
  for repo in "${AIOS_ALL_REPOS[@]}"; do
    local dir="$AIOS_ROOT/$repo"
    if [ ! -d "$dir/.git" ]; then
      log_warn "$repo: not a git repo yet, skipping tracked-file checks"
      continue
    fi
    log_header "Hygiene: $repo"

    if (cd "$dir" && git ls-files | grep -q '\.DS_Store$'); then
      log_fail "$repo: tracked .DS_Store file(s) — run: git rm --cached <path>"
      FAIL=1
    else
      log_pass "$repo: no tracked .DS_Store"
    fi

    if (cd "$dir" && git ls-files | grep -qE '(^|/)(\.build|DerivedData)/'); then
      log_fail "$repo: tracked build artifacts (.build/ or DerivedData/)"
      FAIL=1
    else
      log_pass "$repo: no tracked build artifacts"
    fi

    if [ -f "$dir/.gitignore" ]; then
      log_pass "$repo: has .gitignore"
    else
      log_fail "$repo: missing .gitignore"
      FAIL=1
    fi

    local swift_tracked=() f
    while IFS= read -r f; do
      [ -n "$f" ] && swift_tracked+=("$dir/$f")
    done < <(cd "$dir" && git ls-files '*.swift' 2>/dev/null)
    check_swift_patterns "$repo" "${swift_tracked[@]}"
  done

  check_dependencies
}

if [ "${1:-}" = "--staged" ]; then
  run_staged_mode
else
  run_full_mode
fi

if [ "$FAIL" -eq 0 ]; then
  log_pass "Hygiene checks passed"
else
  log_fail "Hygiene checks failed — see above"
fi
exit "$FAIL"
