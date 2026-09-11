# AGENTS.md — AiOS Project Instructions

## What this is
AiOS — a hub-and-spoke personal AI "context OS" for Apple platforms. A macOS **Hub**
(Mac Studio) does heavy analysis and orchestration; iOS/macOS **Spoke** apps observe
signals and receive insights/actions over a Bonjour LAN transport. SwiftUI + Swift
Concurrency throughout. Core logic lives in the `AiOSCore` Swift package; the apps
(`AiOSHub`, `AiOSBusiness`, `AiOSMyFamily`) depend on it.

Full project context: `context/CONTEXT.md` → `context/memory/MEMORY.md`.

## Architecture (where things live)
- `AiOSCore/Sources/AiOSCore/` — canonical model (Object/Property/Signal), Signal/Insight/
  Action, AnalyticsEngine protocol + engines, ConfidenceEngine, connectors (Plaud, Email),
  Bonjour Transport. This is the reusable brain — keep it UI-free and platform-neutral.
- `AiOSHub/` — the Mac Studio hub app. NOT sandboxed (reads real home dir, orchestrates
  local resources). Hosts the analytics engine + connector fetch services.
- `AiOSBusiness/`, `AiOSMyFamily/` — spoke apps. Sandboxed.

## Non-negotiable rules
1. Never force-unwrap (`!`) outside test files. Use `guard let` / `if let` / `??`.
2. All async is Swift Concurrency (`async`/`await`) — no Combine, no completion-handler chains.
3. Any type crossing an actor/Sendable boundary must be `Sendable`. Fix it, don't suppress.
4. `AiOSCore` stays UI-free (no SwiftUI/AppKit imports) and platform-neutral.
5. No new third-party dependencies without a one-line justification at the import site.
   The whole product thesis is Apple-native; default to Foundation/SwiftUI/FoundationModels.
6. Never ingest proprietary TPW **business data** (CRM records, deals, pricing, meeting
   content) into committed code or memory — kept under `docs/`/`context/`, never hard-coded.
   Tim's own employment history (e.g. "The Part Works" as an employer in résumé fixtures) is
   his factual career record, not TPW business data, and IS allowed. (See context/memory
   work-mac-and-ip.)

## Before you touch code
- State your plan in 3-6 bullets: files touched, new files, model changes, risk/edge cases.
- If the request is ambiguous, ask one clarifying question before writing — don't guess silently.
- Reuse existing types (Signal, Insight, Action, ConfidenceInput, the open-string-wrapper
  IDs like SignalKind/SpokeID). Don't invent parallel models.

## Definition of done (do not report complete unless ALL are true)
- Builds clean — zero new warnings. Use the BuildProject MCP tool (or `xcodebuild`).
- Relevant Swift Testing suites pass — run them, don't assume. (`swift test` in AiOSCore
  for pure-logic changes; scheme tests for app changes.)
- SwiftUI previews render without runtime errors.
- New logic branches have a test.

## Commands
- Build a scheme: `xcodebuild -scheme AiOSHub -destination 'platform=macOS' build`
- Core package tests (fast, no simulator): `cd AiOSCore && swift test`
- Prefer the Xcode MCP tools when available: BuildProject, RunSomeTests,
  XcodeRefreshCodeIssuesInFile (fast single-file diagnostics).
- One-command "definition of done" check (hygiene + build + tests): `scripts/verify.sh [core|hub|business|myfamily]`.
  Fast hygiene-only pass: `scripts/check-hygiene.sh`. Details: `scripts/README.md`.
- Shared pre-commit/pre-push git hooks (staged-file hygiene, then full verify on push) install
  once via `scripts/install-git-hooks.sh` — see `scripts/README.md` for details.

## Style
- 4-space indent. `// MARK:` dividers in files over ~150 lines.
- PascalCase types, camelCase members. `let` by default; `var` only when it mutates.
- Match the surrounding file's comment density and idiom.
- Prefer `struct` + composition; use `class`/actor only when reference semantics or isolation
  genuinely require it.

## Testing framework
- Use **Swift Testing** (`@Test`, `@Suite`, `#expect`) for new tests — NOT XCTest.
- UI tests use XCUIAutomation.

## Critical-review posture
Tim wants proactive, constructive criticism — not agreement. When you see a design problem,
a boil-the-ocean risk, or an unvalidated assumption, say so plainly with the reasoning. Do
not rubber-stamp. (See context/memory always-be-critical.)
