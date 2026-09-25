# AGENTS.md — AiOS Project Instructions

## Core Thesis — read this before anything else, every session

**The problem:** too much data spread in too many places.
**The solve:** have AI cross-reference all of it in a way that surfaces meaningful, actionable suggestions.
**The biggest challenge:** AI hallucinates.
**The solve for that:** confidence ratings on every claim — a human only decides the genuinely ambiguous cases, the "last 20%"; the machine handles the tangible 80% on its own. (This is why *every* engine in this codebase is rule-first with AI behind a seam, and why the grounding gate — "no citation, no claim" — is non-negotiable.)
**How it's delivered:** a central Hub does the heavy processing; spoke devices run what they can locally, but stay deeply intertwined with the Hub — never siloed, never a second source of truth.
**What makes this different from every other AI-productivity tool:** local processing of *your own* content, via the correct AI model, on-device, reaching the correct data through one local index plus external connectors — not a cloud service that ingests your data to serve everyone else's.

**The single most important reframe, easy to lose sight of mid-build:** the spoke apps (`AiOSHub`, `AiOSBusiness`, `AiOSMyFamily`) and every vertical inside them (Job Seeker, Tidy Files, FFA, ExSellerator, Finance, ...) are **examples of the AiOS concept — proof it works on real domains — not the product itself.** The product is the spine: one index, one confidence-scored analytics engine, the Hub/Spoke split, the connector library. A vertical's feature request is never a reason to pull spine work sideways, and a real gap in the spine should never get patched with a vertical-specific workaround — fix it in the spine, once, for every vertical.

Full reasoning behind this, and the current gap between it and what's actually built: `context/inbox/20260922_back-to-basics.md` (Tim's own words, the source) → `docs/architecture/2026-09-22-back-to-basics-review.md` (the gap analysis + spine roadmap this thesis anchors).

## What this is
AiOS — a hub-and-spoke personal AI "context OS" for Apple platforms. A macOS **Hub**
(Mac Studio) does heavy analysis and orchestration; iOS/macOS **Spoke** apps observe
signals and receive insights/actions over a Bonjour LAN transport. SwiftUI + Swift
Concurrency throughout. Core logic lives in the `AiOSCore` Swift package; the apps
(`AiOSHub`, `AiOSBusiness`, `AiOSMyFamily`) depend on it.

**Session start:** read `docs/centerline/00-START-HERE.md` (thesis, current priority, decisions, where
things live). Full project context: `context/CONTEXT.md` → `context/memory/MEMORY.md`.

## Architecture (where things live)
- `AiOSCore/Sources/AiOSCore/` — canonical model (Object/Property/Signal), Signal/Insight/
  Action, AnalyticsEngine protocol + engines, ConfidenceEngine, connectors (Plaud, Email),
  Bonjour Transport. This is the reusable brain — keep it UI-free and platform-neutral.
- `AiOSHub/` — the Mac Studio hub app. NOT sandboxed (reads real home dir, orchestrates
  local resources). Hosts the analytics engine + connector fetch services.
- `AiOSBusiness/`, `AiOSMyFamily/` — spoke apps. **Not sandboxed today** (no app-sandbox entitlement);
  whether to sandbox them is decided at distribution time (Tim, 09-25).

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

7. **Spokes are thin clients.** A spoke captures input (camera, mic, sensors, a form), shows what the
   Hub returns, and keeps only caches and credentials. It never owns a store of record and never reads
   the NAS directly. New features go in the Hub, as a lens over the index, and the spoke reaches them
   through `HubRequest`. (Tim, 09-25. Existing spoke stores are listed in
   `docs/centerline/next-steps-strawman.md` and move under C4.)

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
