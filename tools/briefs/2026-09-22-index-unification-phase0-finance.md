# CLI Brief — Universal Index, Phase 0 (slice 2): FinanceProjectController reachable via HubRequestRouter

**Filed:** 2026-09-22
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md` (context), `tools/briefs/2026-09-22-index-unification-phase0.md` (slice 1, `CaptureStore` — already landed, commits `f6e1744`/`8241469`/`298091b`/`d3c267f`).
**Goal:** Make `FinanceProjectController` (AiOSHub) reachable the same way Job Seeker's `ApplicationController`/`JobDiscoveryController` already are — via `HubRequestRouter`'s injected-closure pattern — so a future spoke-side Finance UI has a real wire path to use, without this brief building that UI itself.

**This is architecturally different from slice 1.** `CaptureStore`/`FFAIngester` are global-actor singletons (`CaptureStore.shared`), reachable from anywhere, so `HubRequestRouter` called them directly. `FinanceProjectController` is `@MainActor @Observable`, currently instantiated as **local `@State` inside `FinanceView`** — not a singleton, not currently reachable from `HubController` at all. The actual gap here is an ownership/wiring problem, not a data-store-split problem (unlike `CaptureStore`, this store's own persistence is already correct — atomic writes were fixed earlier tonight).

**Explicit non-goals:** do NOT build a spoke-side Finance UI (no AiOSMyFamily/AiOSBusiness call sites using the new client methods — this is additive infrastructure only, same posture as slice 1's `.submitCapture` before any UI used it). Do NOT touch `MailIndex`, `TidyIndex`, `ValleyPerinatalStore`, or `EntityDecisionLedger` (later slices). Do NOT touch the dual-AI-engine work (deprioritized behind Library, per Tim).

---

## What already exists — read before writing anything

- `AiOSHub/AiOSHub/HubController.swift` — read the FULL file, especially around where `analysisServers[tenant] = PairedAnalyticsHubServer(...)` is constructed (currently ~line 110). Note exactly how `jobDiscovery`/`appController` are declared as properties on `HubController`, captured as `let discovery = self.jobDiscovery` / `let appCtrl = self.appController` just before server construction, and referenced inside the injected closures via `await MainActor.run { discovery?.results... }` / `appCtrl?.add(...)`. **This exact pattern is your template** — mirror it precisely for a new `financeController` property, don't invent a different shape.
- `AiOSHub/AiOSHub/ContentView.swift` — find where `applications`/`discovery` are declared as `@State` (top-level `ContentView` properties, not inside a child view) and where `hub.jobDiscovery = discovery; hub.appController = applications` gets set (search for that exact line, likely inside a `.task { ... }` block). This is where `FinanceProjectController` needs to move TO — currently it's `@State private var controller = FinanceProjectController()` inside `FinanceView` (a child view), which is why `HubController` can't reach it today.
- `AiOSCore/Sources/AiOSCore/PairedHubService.swift` — `PairedAnalyticsHubServer.init` — the full closure parameter list you're extending (`blueprints`, `listings`, `saveListing`, `applications`, `advanceApplication`). Each has a default no-op value (`{ _ in [] }` etc.) — your new closures need the same default pattern so existing callers/tests that don't pass them still compile.
- `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` — `HubRequestRouter.init` and `handle(_:)` — same closure-injection pattern, same default-value convention. Read the existing `.fetchApplications`/`.advanceApplication` arms as your direct template for the new Finance arms.
- `AiOSCore/Sources/AiOSCore/Transport.swift` — full file. `FetchApplicationsRequest`/`FetchApplicationsResponse`/`AdvanceApplicationRequest` are your shape template for the new Finance request/response structs (each carries `tenant: Tenant` — confirm whether Finance data should be tenant-scoped the same way, or whether `workspaceScope`/`FinanceWorkspaceScope` on `FinanceProject` already does that job and tenant-scoping would be redundant — check `FinanceWorkspaceScope`'s real shape before deciding, don't assume).
- `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` — `fetchApplications()`/`advanceApplication(id:to:)` — your template for the new spoke-side convenience methods (which will exist but have no caller yet, per the non-goals above).
- `AiOSHub/AiOSHub/FinanceView.swift` — `FinanceProjectController` (currently ~line 548): `projects`, `transactions`, `plannedBudgets`, `transactions(for:)`, `addProject(name:kind:settlementPolicy:)`, `addTransaction(to:date:description:category:direction:amount:)`, `setPlannedBudget(_:for:)`. Read the WHOLE class — this brief hoists its ownership, it does not change its internals.

---

## What to build

### 1. New `HubRequest`/`HubReply` cases, `Transport.swift`

Mirror the Job Seeker shape exactly. Suggested (adjust field names to match what you actually find on `FinanceProject`/`CanonicalFinancialTransaction` — don't guess at exact property names, read `AiOSCore/Sources/AiOSCore/Finance/FinanceProject.swift` and the transaction type first):

```swift
// requests/responses (new structs, Sendable/Codable, mirror FetchApplicationsRequest's shape)
public struct FetchFinanceProjectsRequest: Sendable, Codable { public let tenant: Tenant }
public struct FetchFinanceProjectsResponse: Sendable, Codable {
    public let projects: [FinanceProject]
    public let transactions: [CanonicalFinancialTransaction]
}
public struct SubmitFinanceTransactionRequest: Sendable, Codable {
    public let tenant: Tenant
    public let projectID: String
    // ... whatever addTransaction(to:date:description:category:direction:amount:) actually needs as inputs
}

// HubRequest additions:
case fetchFinanceProjects(FetchFinanceProjectsRequest)
case submitFinanceTransaction(SubmitFinanceTransactionRequest)

// HubReply additions:
case financeProjects(FetchFinanceProjectsResponse)
case financeTransactionSubmitted
```

### 2. `HubRequestRouter.swift` — injected closures + dispatch arms

Add to `init`, same default-value convention as existing params:
```swift
financeProjects: @escaping @Sendable (Tenant) async -> FetchFinanceProjectsResponse = { _ in FetchFinanceProjectsResponse(projects: [], transactions: []) },
submitFinanceTransaction: @escaping @Sendable (Tenant, SubmitFinanceTransactionRequest) async -> Void = { _, _ in }
```
Dispatch arms in `handle(_:)`, mirroring `.fetchApplications`/`.advanceApplication` exactly:
```swift
case .fetchFinanceProjects(let req):
    return .financeProjects(await financeProjects(req.tenant))
case .submitFinanceTransaction(let req):
    await submitFinanceTransaction(req.tenant, req)
    return .financeTransactionSubmitted
```

### 3. `PairedHubService.swift` — thread the closures through `PairedAnalyticsHubServer.init`

Add the same two closure params (with the same default values), pass through to the internal `HubRequestRouter(...)` construction.

### 4. `HubController.swift` — hoist `financeController`, wire the closures

- Add `var financeController: FinanceProjectController?` as a property (mirror `appController`/`jobDiscovery`'s exact declaration — check if they're `weak var` or plain `var`; match it).
- At the `PairedAnalyticsHubServer(...)` construction site, capture `let financeCtrl = self.financeController` (mirroring `let appCtrl = self.appController`) and pass the two new closures:
```swift
financeProjects: { _ in
    await MainActor.run {
        FetchFinanceProjectsResponse(projects: financeCtrl?.projects ?? [], transactions: financeCtrl?.transactions ?? [])
    }
},
submitFinanceTransaction: { _, req in
    await MainActor.run {
        guard let project = financeCtrl?.projects.first(where: { $0.id == req.projectID }) else { return }
        financeCtrl?.addTransaction(to: project, date: /* from req */, description: /* from req */, category: /* from req */, direction: /* from req */, amount: /* from req */)
    }
}
```

### 5. `ContentView.swift` (AiOSHub) — hoist `FinanceProjectController` ownership

- Move `FinanceProjectController`'s instantiation from `FinanceView`'s local `@State` to `ContentView`'s top-level `@State` (matching exactly how `applications`/`discovery` are declared).
- Pass it into `FinanceView` as an initializer parameter (`FinanceView(controller: financeController)` or similar — check `FinanceView`'s current init shape and adjust minimally).
- Set `hub.financeController = financeController` in the same `.task { }` block (or an adjacent one) where `hub.jobDiscovery`/`hub.appController` get set.
- **Verify `FinanceView` still compiles and behaves identically from the user's perspective** — this is a pure ownership move, the UI should look and act exactly the same before and after.

### 6. `PairedHubClient.swift` — spoke-side convenience methods

```swift
public func fetchFinanceProjects() async throws -> FetchFinanceProjectsResponse {
    guard case .financeProjects(let response) = try await send(.fetchFinanceProjects(FetchFinanceProjectsRequest(tenant: tenant))) else {
        throw /* whatever error type fetchApplications() throws on a shape mismatch — match its pattern */
    }
    return response
}
public func submitFinanceTransaction(_ request: SubmitFinanceTransactionRequest) async throws {
    _ = try await send(.submitFinanceTransaction(request))
}
```
(Adjust to match `fetchApplications()`'s actual error-handling shape — read it first, don't invent a different error convention.)

---

## Tests

Add to `AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift`, mirroring the existing `.fetchApplications`/`.advanceApplication` test shape:
- `.fetchFinanceProjects` with an injected closure returns the expected response.
- `.submitFinanceTransaction` calls the injected closure with the right tenant + request.
- Default (no closure provided) `.fetchFinanceProjects` returns an empty response, doesn't crash.

No AiOSHub-level test is required for the `ContentView`/`HubController` wiring (no existing test harness covers that layer) — but you MUST manually verify (via the build, and by reading the diff) that `hub.financeController` actually gets set and that `FinanceView` still renders identically.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
(No AiOSMyFamily/AiOSBusiness changes expected in this brief — if you find yourself touching either, stop and reconsider, that's out of scope per the non-goals above.)

Zero errors, zero new warnings.

---

## Acceptance criteria

1. `HubController` has a `financeController` property, set the same way `appController`/`jobDiscovery` are.
2. `FinanceProjectController` is owned by `ContentView`, not `FinanceView` — `FinanceView` receives it, doesn't create it.
3. `.fetchFinanceProjects`/`.submitFinanceTransaction` work end-to-end through `HubRequestRouter` (proven by test), even though no spoke UI calls them yet.
4. `FinanceView`'s behavior is unchanged from the user's perspective — this is a pure wiring/ownership change.
5. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
feat(index): Finance Phase 0 slice 2 — hoist FinanceProjectController, wire HubRequestRouter reachability

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (Transport/HubRequestRouter/PairedHubService/PairedHubClient), AiOSHub (HubController/ContentView — FinanceProjectController ownership hoist).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/Transport.swift` | AiOSCore | MODIFY — new request/response structs + HubRequest/HubReply cases |
| `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` | AiOSCore | MODIFY — injected closures + dispatch arms |
| `AiOSCore/Sources/AiOSCore/PairedHubService.swift` | AiOSCore | MODIFY — thread closures through `PairedAnalyticsHubServer.init` |
| `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` | AiOSCore | MODIFY — `fetchFinanceProjects()`/`submitFinanceTransaction(_:)` |
| `AiOSHub/AiOSHub/HubController.swift` | AiOSHub | MODIFY — `financeController` property + closure wiring |
| `AiOSHub/AiOSHub/ContentView.swift` | AiOSHub | MODIFY — hoist `FinanceProjectController` ownership |
| `AiOSHub/AiOSHub/FinanceView.swift` | AiOSHub | MODIFY — receive controller as a parameter instead of owning it |
