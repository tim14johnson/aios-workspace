# CLI Brief — Test the connector library for real: wire Plaud into a live `ConnectorSlot`, add an injectable transport

**Filed:** 2026-09-23
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 2 section (connector-checkout, landed commits AiOSCore `f5330fa`/AiOSBusiness `0955b20`).
**Priority context:** Tim asked to exercise the connector-checkout mechanism built tonight against already-connected real content. A research pass found Plaud is the one clean candidate among Plaud/Toggl/jobspy — it's already a genuine `SpokeConnector` conformer, just never actually constructed anywhere outside its own test file (dormant, same shape `ConnectorSlot` itself was before tonight). Toggl and jobspy are NOT candidates for this brief — see the two explicit non-goals below, they need different, separate work first (or, for jobspy, shouldn't be forced into this abstraction at all).

**What this brief actually proves:** the connector-checkout mechanism (wired tonight for Job Seeker's two connectors) generalizes to a third, real, independently-built connector — not something special-cased for the two it launched with. It also closes a real testability gap found while scoping: `PlaudConnector`'s underlying `PlaudMCPClient` (`AiOSCore/Sources/AiOSCore/PlaudConnector.swift`) has a hardcoded `URLSession` with no injectable transport, unlike `RemoteAnalyticsEngine.Transport`'s established pattern — so there's currently no way to test a full successful Plaud fetch without live Plaud credentials. Fix that too, so "testing the connector library" actually means something beyond wiring.

**Explicit non-goals:**
- Do NOT touch Toggl (`TogglConnector.swift`/`TogglFetcher.swift`/`TogglBillingSync.swift`) or jobspy (`JobSpyProcessRunner.swift`) in any way. Confirmed via research tonight: Toggl has a real, smaller, separate duplication (`TogglConnector.get(...)` and `TogglFetcher.fetchEntries(...)` independently hand-roll the identical Basic-auth HTTP call) that's a different, future slice — not part of this brief. jobspy is Hub-side, bulk-scrape-shaped, and a poor fit for `SpokeConnector` entirely; don't force it.
- Do NOT touch `AiOSMyFamily` — Plaud is deliberately macOS-only (see `PlaudConnector.swift`'s own doc comment: no OAuth-install path exists on iOS, no access to the `~/.plaud/tokens-mcp.json` file even if one did). This brief is AiOSCore + AiOSBusiness only.
- Do NOT change `PlaudMCPProcess`/`PlaudFetchService` (the separate, already-live AiOSHub feature that also talks to Plaud) — `PlaudConnector`'s own doc comment explicitly says it's a self-contained port, deliberately not sharing that code, to avoid cross-target coupling. Leave that boundary exactly as-is.
- Do NOT rebuild `ConnectorSlot`/`BlueprintConfiguration` themselves — consume as-is, proven correct tonight.
- Do NOT attempt to obtain or configure real Plaud credentials — this is code/test infrastructure work; a live end-to-end test with Tim's actual Plaud device is something he does himself, later.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/PlaudConnector.swift` — full file, already read tonight while scoping. `PlaudConnector: SpokeConnector` (`connectorID = "com.aios.connector.plaud"`, `domainIdentifier = "audio.transcription"`), `init(ledger: CrawlLedger)`, `fetch()` constructs its own `PlaudMCPClient()` internally (not injected) and returns an empty `ConnectorOutput()` on any auth/network failure rather than throwing (deliberately offline-safe). `PlaudMCPClient` (same file, ~line 120+) has `private lazy var session: URLSession = { ... }()` — hardcoded, no injection seam — and `func start() async throws` which does the actual OAuth-token-file read + MCP handshake.
- `AiOSCore/Sources/AiOSCore/RemoteAnalyticsEngine.swift` — the established injectable-transport idiom to mirror: `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)`, an `init(config:transport:)` defaulting to real `URLSession.shared.data(for:)` when `nil`. Match this exact shape for `PlaudMCPClient`, don't invent a different transport abstraction.
- `AiOSCore/Sources/AiOSCore/ConnectorSlot.swift` — `ConnectorType` already has a `case plaud` sitting unused (line ~20-21) alongside `.toggl` — real evidence this was anticipated. `BlueprintConfiguration.activeConnectorID(forSlot:in:)` is the resolution mechanism, proven tonight.
- `AiOSCore/Sources/AiOSCore/JobSeekerBlueprint.swift` — the one real `Blueprint` with populated `connectorSlots` today (`"photo-library"` → `PhotoLibraryConnector`, `"system-health"` → `SystemHealthConnector`, added tonight). **Read this before deciding where Plaud's slot goes.** There is no other dual-platform vertical's `Blueprint` with populated `connectorSlots` today — `NoteBlueprintLibrary`/`NoteBlueprint` (Session Notes' own blueprint concept) is a **completely different, unrelated type**, not the `Blueprint`/`ConnectorSlot` system at all; don't confuse the two or try to wire Plaud through it.
- **A real, honestly-flagged ambiguity, not resolved yet:** there's no obviously-fitting semantic home for an audio-transcription connector in `JobSeekerBlueprint` specifically — but note that `system-health` (added tonight) has no obvious Job-Seeker-domain tie either, and `AiOSBusinessApp.swift` already injects `SystemHealthConnector` alongside `PhotoLibraryConnector` regardless. This suggests AiOSBusiness's spoke already serves, in practice, as a general connector testbed for whatever's macOS-capable and worth proving — not a strictly narrow single-domain slot set. **Recommended:** add Plaud as a third slot on `JobSeekerBlueprint` for exactly that reason (proving the mechanism against a third real connector, matching the precedent already set by `system-health`'s inclusion). If you find a more fitting Blueprint while reading the real code, use it instead and explain your reasoning — this is a genuine judgment call, not a fixed instruction.
- `AiOSBusiness/AiOSBusiness/AiOSBusinessApp.swift` — the real construction site: `SpokeController(tenant: .business, connectors: [PhotoLibraryConnector(...), SystemHealthConnector(...)], blueprint: JobSeekerBlueprint.blueprint)`. `PlaudConnector` needs to be added here too, but **must be platform-gated** (`#if os(macOS)`) — this file builds for iOS too, and `PlaudConnector` cannot exist there (no `~/.plaud/` access). Check how `ComputeWorker`/other macOS-only pieces are already conditionally compiled elsewhere in this codebase (e.g. `SpokeController.swift`'s own `#if os(macOS) private var computeWorker...#endif`) and match that idiom — don't let this be the brief that breaks the iOS Simulator build the way an earlier one did tonight.
- `AiOSCore/Tests/AiOSCoreTests/PlaudConnectorTests.swift` — full file, existing coverage: `connectorID`/`domainIdentifier` stability, no-credentials failure path (via an injectable `tokenPathOverride` that already exists). Read it to understand the existing test idiom before adding new tests.

---

## What to build

### 1. Injectable transport for `PlaudMCPClient`

Add a `Transport` typealias (mirroring `RemoteAnalyticsEngine.Transport`'s exact shape) and an injection point on `PlaudMCPClient`/`PlaudConnector`'s init, defaulting to the real `URLSession` when not provided. This must not change any real, live behavior when unconfigured — purely additive, same bar as every other extraction tonight.

### 2. A real happy-path test using the new transport

Using a fake `Transport` closure that returns a canned, correctly-shaped MCP response, write a test proving `PlaudConnector.fetch()` produces real `ConnectorOutput` facts from a successful (simulated) Plaud call — something the existing test suite cannot do today (it only covers the no-credentials failure path). This is the actual "test the connector library" proof for Plaud.

### 3. Wire Plaud into `JobSeekerBlueprint`'s `connectorSlots` (or your better-grounded alternative — see the ambiguity note above)

Add a third `ConnectorSlot` (`slotID` your call, e.g. `"plaud"`, `acceptedTypes: [.plaud]`, `activeConnectorID` matching `PlaudConnector`'s real `connectorID` string `"com.aios.connector.plaud"`). `isRequired: false` (matching the existing two slots' rationale — best-effort connectors, `gatherSignals()` tolerates any one failing).

### 4. Construct and platform-gate it in `AiOSBusinessApp.swift`

Add `PlaudConnector(ledger: .applicationSupport(appFolder: "AiOSBusiness", fileName: "plaud-recordings-crawl.json"))` (check `CrawlLedger`'s real construction API — mirror `PhotoLibraryConnector`'s existing ledger construction exactly) to the connectors array, wrapped in `#if os(macOS)` so the iOS build never sees it. `SpokeController.resolvedConnectors()` (from tonight's connector-slot-wiring slice) already filters the injected array against the Blueprint's active slot IDs — confirm this composes correctly with a conditionally-empty array on iOS (i.e., the Blueprint can declare the `plaud` slot unconditionally; the connector simply won't exist to resolve against on iOS, and that's the correct, safe outcome — not an error).

---

## Tests

- New transport-injection tests for `PlaudMCPClient`/`PlaudConnector` (the happy-path proof from step 2 above).
- Confirm `PlaudConnectorTests.swift`'s existing tests still pass, unmodified in intent.
- If `ConnectorSlotTests.swift`/`JobSeekerBlueprint`-related tests exist checking the exact slot count/set (from tonight's connector-slot-wiring slice), update them to account for the third slot — read what they assert first.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on all three. The iOS Simulator build succeeding with Plaud correctly absent (not present, not erroring) is the specific proof the platform-gating worked.

---

## Acceptance criteria

1. `PlaudMCPClient` has a real injectable transport, matching `RemoteAnalyticsEngine.Transport`'s established idiom.
2. A new test proves a full, successful (simulated) Plaud fetch produces real `ConnectorOutput` — not just the failure path.
3. `JobSeekerBlueprint` (or your better-grounded alternative) has a real, live third connector slot resolving to `PlaudConnector`.
4. `AiOSBusinessApp.swift` constructs it, correctly platform-gated — iOS build proves its absence there is clean, not broken.
5. All three build/test combinations green.

---

## Commit

```
feat(library): wire Plaud into a real ConnectorSlot, add an injectable transport for real testability

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore, AiOSBusiness.

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/PlaudConnector.swift` | AiOSCore | MODIFY — injectable transport |
| `AiOSCore/Sources/AiOSCore/JobSeekerBlueprint.swift` (or alternative, justified) | AiOSCore | MODIFY — third connector slot |
| `AiOSCore/Tests/AiOSCoreTests/PlaudConnectorTests.swift` | AiOSCore | MODIFY — happy-path test |
| `AiOSBusiness/AiOSBusiness/AiOSBusinessApp.swift` | AiOSBusiness | MODIFY — construct + platform-gate |
