# AiOS repo-hygiene scripts

Lightweight, dependency-free enforcement of the standards in [`AGENTS.md`](../AGENTS.md).
Pure `bash` + `git` + `xcodebuild`/`swift` — no SwiftLint, no fastlane, no new dependencies,
per AGENTS.md rule 5.

## Layout

```
code/
  AGENTS.md
  scripts/
    lib/common.sh              # shared helpers (colors, target/repo resolution) — sourced, not run
    check-hygiene.sh           # repo hygiene: tracked junk, banned imports, force-unwraps,
                                #   proprietary-data leaks, undeclared dependencies
    check-build.sh             # build cleanliness: fails on build errors OR any warning
    check-tests.sh             # runs the relevant test suite and checks it actually passed
    verify.sh                  # runs all three — the "definition of done" in one command
    install-git-hooks.sh       # one-time setup: wires the hooks below into all 4 sub-repos
    allowed-dependencies.txt   # allowlist for AGENTS.md rule 5 (empty today)
  githooks/
    pre-commit                 # fast: staged-file hygiene only
    pre-push                   # thorough: full verify.sh for the repo being pushed
  ci/
    github-actions.yml.example # reference template for when a git remote exists (see caveat inside)
```

## Why scripts live outside the 4 git repos

`AiOSCore`, `AiOSHub`, `AiOSBusiness`, and `AiOSMyFamily` are each their own independent git
repo (see `AGENTS.md`'s architecture section) — there's no single top-level repo tying them
together, just this plain folder plus `AiOS.xcworkspace`. Putting the scripts here once,
instead of duplicating them into all 4 repos, keeps one source of truth. Git hooks can point
at a sibling directory via `core.hooksPath`, so this works cleanly for hooks. It does **not**
work out of the box for real CI (a CI runner only checks out one repo at a time) — see the
caveat comment in `ci/github-actions.yml.example` for what to do about that if/when a remote
is added.

## Commands

```bash
# Run everything (hygiene + build + tests) for every target
scripts/verify.sh

# Just the fast core package (no simulator, seconds not minutes)
scripts/verify.sh core

# Just one app
scripts/verify.sh hub        # AiOSHub
scripts/verify.sh business   # AiOSBusiness
scripts/verify.sh myfamily   # AiOSMyFamily

# Individual checks
scripts/check-hygiene.sh                 # all 4 repos, tracked files
scripts/check-hygiene.sh --staged        # current repo, staged files only (what pre-commit runs)
scripts/check-build.sh <target|all>
scripts/check-tests.sh <target|all>

# One-time: install the shared git hooks into all 4 sub-repos
scripts/install-git-hooks.sh
```

## What gets checked

**Hygiene** (`check-hygiene.sh`) — fast, no build required:
- Tracked `.DS_Store` files or `.build`/`DerivedData` directories per sub-repo
- Missing `.gitignore` per sub-repo
- Merge-conflict markers in Swift files
- `import Combine` (AGENTS.md rule 2 — Swift Concurrency only)
- Force-unwrap / `try!` / `as!` outside test files (AGENTS.md rule 1) — **advisory**, not a
  hard fail; some are legitimate, but you should look
- Literal `"The Part Works"` / `TPW` strings outside `docs/` or `context/` (AGENTS.md rule 6)
- Undeclared third-party SwiftPM dependencies vs. `scripts/allowed-dependencies.txt`
  (AGENTS.md rule 5)

**Build** (`check-build.sh`) — fails on build errors *or* any compiler warning (today's
baseline is zero warnings; the cheapest way to keep it that way is to never let one land).

**Tests** (`check-tests.sh`) — actually runs `swift test` (AiOSCore) or `xcodebuild test`
(apps) and checks the exit code, rather than assuming green.

## Git hooks

After running `scripts/install-git-hooks.sh` once:

- **pre-commit** (every commit, all 4 repos): staged-file hygiene only — sub-second, never
  blocks on a build.
- **pre-push** (every push, all 4 repos): full `scripts/verify.sh <target>` for whichever
  repo you're pushing — this is where build/test enforcement actually bites.

Bypass either on a one-off basis with `git commit --no-verify` / `git push --no-verify`.
Uninstall for one repo with `git -C <repo> config --unset core.hooksPath`.

## Known limitations (read before trusting this blindly)

- The force-unwrap/`try!`/`as!` and proprietary-data checks are `grep` heuristics, not a
  real Swift parser. They'll have false positives (e.g. a legitimate trailing `!` in a
  string) and could in theory miss things a linter would catch. Treat hits as "go look,"
  not gospel.
- The dependency check only understands `.package(url:)` in `Package.swift` and
  `repositoryURL =` in `project.pbxproj`. If Apple changes the pbxproj format for package
  references, this will need a small update — check `scripts/check-hygiene.sh`'s
  `check_dependencies` function.
- `check-build.sh`/`check-tests.sh` for the three apps assume the default Xcode-generated
  scheme names (`AiOSHub`, `AiOSBusiness`, `AiOSMyFamily`) and a `macOS` destination —
  confirmed against the current `.xcscheme` files, but if a scheme is renamed these will
  need updating in `scripts/lib/common.sh`'s `target_scheme()`.
- No CI is actually wired up yet (no git remote exists for any of the 4 repos). See the
  caveat in `ci/github-actions.yml.example`.
