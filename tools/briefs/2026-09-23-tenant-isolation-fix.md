# CLI Brief — Close the tenant-isolation gap: `HubRequestRouter` must use the connection's real tenant, never the client's claim

**Filed:** 2026-09-23
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md` (Valley Perinatal section flags this exact gap).
**Priority context:** Tim confirmed this as the top priority tonight, ahead of further Index/Library work. This is a real, provable security-relevant bug, not a design ambiguity — `Tenant`'s own doc comment (`AiOSCore/Sources/AiOSCore/Tenant.swift:3-5`) already states the intended contract: *"a hard boundary... Each tenant is advertised as its own Bonjour service so the two never share a listener, an allowlist, or an analysis path ('physical' separation)."* The bug is that `HubRequestRouter` doesn't actually honor that contract — it trusts whatever `tenant` field the client puts in its request payload instead of the tenant of the connection that's actually talking to it.

**Root cause, confirmed by reading the real code tonight:** `HubController.start()` (`AiOSHub/AiOSHub/HubController.swift`) constructs one `PairedAnalyticsHubServer` per tenant inside `for tenant in tenants` (line 99) — each instance is genuinely, structurally bound to one tenant (its own `NWListener`, its own tenant-specific PSK set, confirmed in `PairedHubService.swift`). But `HubRequestRouter` (`AiOSCore/Sources/AiOSCore/HubRequestRouter.swift`) — constructed inside `PairedAnalyticsHubServer.init` and handed the same closures — has **no tenant of its own**. Every route in its `handle(_:)` method extracts `req.tenant` (a field the *client* set on the request it sent) and passes that straight to the injected closures: `blueprints(req.tenant)`, `financeProjects(req.tenant)`, `submitFinanceTransaction(req.tenant, req)`, etc. — for all 8 tenant-scoped routes (`syncBlueprints`, `fetchListings`, `saveListing`, `fetchApplications`, `advanceApplication`, `fetchFinanceProjects`, `submitFinanceTransaction`, `submitBillableTimeEntries`). A device paired to the `.family` listener can send a request claiming `tenant: .business` and every one of these routes will honor that claim. This is a real, live gap — Valley Perinatal's just-shipped sync depends on it today (a `.family`-paired AiOSMyFamily device reads `.business`-tenant Finance data via an explicit tenant override).

**Decision already made by Tim — read before building:** the fix is the strict interpretation, no exceptions, no per-device grant mechanism. Cross-tenant access that's genuinely needed (Valley Perinatal, and per Tim tonight, likely future cases: AdSWAG, Mazzaroth Pictures archive data, other ventures with tax implications) will be solved by **duplicating the specific records that need to cross the boundary** (tax/invoice-relevant Finance records, into the Family/Personal workspace), not by loosening the boundary itself. That duplication mechanism is explicitly **out of scope for this brief** — a separate, later piece of work once its shape is defined. This brief's job is only to make the boundary itself actually hold.

**Explicit non-goals:**
- Do NOT build any duplication mechanism, grant/ACL system, or per-device cross-tenant allowlist. Not this brief.
- Do NOT re-pair AiOSMyFamily as `.business` for Valley Perinatal, and do NOT worry about VPS's live sync breaking as a result of this fix landing — that's an accepted, already-agreed, separately-sequenced follow-on. Just note in your report that it will now be broken (it will — this is expected and fine).
- Do NOT change `Tenant`, `PairingHandshakeServer`, or the pairing/PSK layer itself — those are already correctly tenant-scoped. Only `HubRequestRouter` (and its construction in `PairedHubService.swift`) need to change.
- Do NOT remove the `tenant` field from the wire-format request structs (`SyncBlueprintsRequest`, `FetchFinanceProjectsRequest`, `SubmitFinanceTransactionRequest`, etc.) — that would ripple through every `PairedHubClient` call site across AiOSHub/AiOSBusiness/AiOSMyFamily for no real benefit. Keep the field on the wire; just stop trusting it for authorization.
- Do NOT touch `CaptureStore`/`.submitCapture`/FFA routes (`submitFFAEntry`/`submitFFABatch`) — confirmed these don't take a tenant parameter today (`CaptureStore` isn't tenant-partitioned). If you discover otherwise while reading the real code, report it, but don't fix it in this brief — flag it as a separate finding.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/Tenant.swift` — full file, read the doc comment above the type in full (lines 1-10ish) before anything else. This is the contract you're restoring.
- `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` — full file, already read in full tonight while scoping this brief. `handle(_:)` has exactly 8 places using `req.tenant`: lines 59, 71, 74, 78, 81, 113, 116, 120 (line numbers as of tonight — verify against current file, don't assume they haven't shifted). The struct currently has no `tenant` property.
- `AiOSCore/Sources/AiOSCore/PairedHubService.swift` — full file. `PairedAnalyticsHubServer` has `self.tenant: Tenant` (set in `init`, confirmed real and connection-authoritative — this instance's listener only ever accepts connections for this tenant). It constructs `HubRequestRouter(engine: engine, blueprints: blueprints, ..., financeProjects: financeProjects, submitFinanceTransaction: submitFinanceTransaction, submitBillableTimeEntries: submitBillableTimeEntries)` around line 116-128 — this call site needs to pass the router its own `tenant`.
- `AiOSHub/AiOSHub/HubController.swift` — `start()`, lines ~99-178. Confirms the outer `for tenant in tenants` loop is correct and authoritative; the closures at lines 138 (`financeProjects: { tenant in ... }`), 146 (`submitFinanceTransaction: { tenant, req in ... }`), 159 (`submitBillableTimeEntries: { tenant, req in ... }`) currently receive whatever `HubRequestRouter` passes them — once the router is fixed to use its own bound tenant instead of `req.tenant`, these closures will automatically receive the correct, connection-authoritative tenant with zero changes needed here. **Confirm this is true by reading it, don't just assume — if `HubController.swift` needs any change at all after the router fix, report exactly why.**
- `AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift` — full file. At least 10 existing call sites construct `HubRequestRouter(engine: EchoEngine())` or similar without any tenant argument — these will need updating once `tenant:` becomes a required init parameter (see below). Read every existing test to understand what each one is actually asserting before touching it, so you preserve intent while fixing compilation.
- `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` — check for the `tenant:` override parameter added to `fetchFinanceProjects(tenant:)` during tonight's Valley Perinatal slice (commit `4735410`). Once this fix lands, that override becomes inert — the Hub will ignore the claimed tenant and use the connection's own regardless. Grep for any other callers of that override before deciding whether to remove the now-misleading parameter entirely or leave it with a corrected doc comment explaining it's now ignored server-side — your call, but removing it is probably more honest than leaving a parameter that silently does nothing. Check for other call sites first.

---

## What to build

### 1. `HubRequestRouter` becomes tenant-scoped at construction

Add a required `tenant: Tenant` stored property and init parameter (no default — this is a security-relevant type, an accidental default could silently reintroduce the bug in a future call site). Update every one of the 8 `req.tenant` references in `handle(_:)` to use `self.tenant` instead. The `req.tenant` field itself stays on the wire-format structs (per the non-goals above) — it's simply no longer read for authorization.

**Recommended, not required — defense in depth:** log (via whatever this codebase's existing lightweight logging idiom is — check `note(...)`/`print(...)` usage elsewhere in similar files) when `req.tenant != self.tenant`, so a client claiming a different tenant than its actual connection shows up as a visible signal rather than being silently overridden. This is pure diagnostic upside; it must never change the actual authorization outcome (always use `self.tenant`, regardless of what's logged).

### 2. `PairedAnalyticsHubServer` passes its own tenant to the router

In `PairedHubService.swift`, update the `HubRequestRouter(...)` construction to include `tenant: self.tenant`.

### 3. Update every existing test call site

Every `HubRequestRouter(engine: ...)` construction in `HubRequestRouterTests.swift` needs a `tenant:` argument now. For tests that aren't specifically about tenant behavior, pick any consistent tenant value (check what `Tenant` cases/values already exist and are used elsewhere in this test file — likely `.family`/`.business` or similar, don't invent new ones). Read each test's actual assertion first to make sure adding this parameter doesn't silently change what it's testing.

### 4. New tests proving the fix

Add tests that construct a `HubRequestRouter(tenant: .family, ...)` and send it a request whose payload claims `tenant: .business` (or vice versa) — assert the injected closure receives `.family` (the router's own bound tenant), not `.business` (the request's claim). Cover at least one Finance route (`fetchFinanceProjects` or `submitFinanceTransaction`) and one non-Finance route (e.g. `fetchApplications`) to prove the fix is systematic, not Finance-specific.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. Grep for any other repo (AiOSBusiness, AiOSMyFamily) constructing `HubRequestRouter` directly (expected: none — it's Hub-only, constructed inside `PairedAnalyticsHubServer`) — confirm via grep, don't assume.

---

## Acceptance criteria

1. `HubRequestRouter` is tenant-scoped at construction; every route uses its own bound tenant, never the request payload's claimed tenant, for authorization.
2. `PairedAnalyticsHubServer` passes its real, connection-authoritative tenant to the router it constructs.
3. New tests prove a request claiming a different tenant than the router's own bound tenant is resolved against the router's tenant, not the claim — for at least one Finance and one non-Finance route.
4. All existing tests updated to compile with the new required parameter, with intent preserved (verified by reading, not just by green).
5. Confirmed and reported: this fix will break Valley Perinatal's current live cross-tenant sync (expected, already agreed, tracked as a separate follow-on — not something to silently work around here).
6. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
fix(security): HubRequestRouter must authorize by the connection's real tenant, never the client's claimed tenant

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore only, expected (confirm via grep before assuming).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` | AiOSCore | MODIFY — add `tenant`, use `self.tenant` everywhere, not `req.tenant` |
| `AiOSCore/Sources/AiOSCore/PairedHubService.swift` | AiOSCore | MODIFY — pass `tenant: self.tenant` to the router it constructs |
| `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` | AiOSCore | MODIFY — remove or clearly re-document the now-inert `tenant:` override on `fetchFinanceProjects`, after checking for other callers |
| `AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift` | AiOSCore | MODIFY — update all call sites, add new tenant-enforcement tests |
