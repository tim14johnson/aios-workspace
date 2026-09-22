# CLI Brief — Universal Index, Phase 0 (slice 3): FinanceProjectController tenant-scoping

**Filed:** 2026-09-22
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md`, `tools/briefs/2026-09-22-index-unification-phase0.md` (slice 1, landed), `tools/briefs/2026-09-22-index-unification-phase0-finance.md` (slice 2, landed — this brief closes the exact gap slice 2's report flagged: "the hub-side closures ignore `req.tenant` entirely... because `FinanceProjectController` has no tenant-scoped storage to filter by").
**Goal:** Make `FinanceProjectController` actually respect `Tenant`/`FinanceWorkspaceScope` instead of hardcoding `.personal`/`.myFamily` for every project and transaction, regardless of who's asking.

**Real-world grounding, not a hypothetical:** Tim has already partially separated his real data into two physical folders — `/Volumes/01_Tims-Projects/AiOS/Business/` and `/Volumes/01_Tims-Projects/AiOS/My Family/` — confirming the tenant split is genuinely two-way: `Tenant.business` (Mazzaroth Pictures — the entity behind every `com.mazzarothpictures.*` bundle ID in this whole project — plus a former venture, AdSWAG) and `Tenant.family` (household + personal finances). The separation on disk is incomplete (some Mazzaroth/AdSWAG records still sit under `My Family/AiOS Finance/`) — that's a Tidy Files file-organization problem, explicitly OUT OF SCOPE for this brief. This brief is about the in-app data model catching up to a split that already exists conceptually and partially on disk.

**The good news:** the domain model for this already exists and was built correctly nine days ago (`AiOSCore/Sources/AiOSCore/Finance/FinanceWorkspace.swift`, commit `b56510e`, 2026-09-13) — `FinanceWorkspaceKind.myFamily`/`.business`, `FinanceWorkspaceScope(tenant:workspaceKind:organizationID:)`, `FinancialOrganization` (with `FinancialOrganizationKind.currentBusiness`/`.formerBusiness`/`.freelanceSoleProp`/`.household` — this literally already models "Mazzaroth Pictures = currentBusiness, AdSWAG = formerBusiness, household finances = household"). It was just never wired into the actual running `FinanceProjectController`. **This is a wiring slice, not a new-model slice.**

**Explicit non-goals:** do NOT reorganize any files under `/Volumes/01_Tims-Projects/AiOS/` — that's real financial data and a separate, explicit task. Do NOT build UI for creating/editing `FinancialOrganization` records (e.g. registering "Mazzaroth Pictures" as an org) — that's real feature work; this brief only needs the SCOPE plumbing to work, defaulting sensibly when no organization is registered yet. Do NOT touch `MailIndex`/`TidyIndex`/`ValleyPerinatalStore`/`EntityDecisionLedger` (later slices). Do NOT touch the dual-engine work.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/Finance/FinanceWorkspace.swift` — the FULL file (already read once, only 161 lines). `FinanceWorkspaceKind`, `FinanceWorkspaceScope`, `FinancialOrganization`, `FinancialOrganizationKind`, `FinancialAccount`, `FinancialAccountType`. Your primitives — do not redefine any of these.
- `AiOSCore/Sources/AiOSCore/Finance/FinanceProject.swift` — confirm `FinanceProject`'s real init signature (it takes `scope: Scope` and `workspaceScope: FinanceWorkspaceScope` today — confirm both fields still exist with those exact names/types before writing code against them).
- `AiOSCore/Sources/AiOSCore/Finance/CanonicalFinancialTransaction.swift` — same, for the transaction type (`scope`, `workspaceScope` fields).
- `AiOSHub/AiOSHub/FinanceView.swift` — `FinanceProjectController` (currently ~line 548 area, may have shifted after slice 2's edits — search for the class, don't trust a line number). Current state: `addProject`/`addTransaction` hardcode `scope: .personal, workspaceScope: .myFamily` (found via direct grep — two call sites). `projects`/`transactions`/`plannedBudgets` are flat arrays with no tenant filtering anywhere. The `Picker` for `FinanceProjectKind` in the "Add project" UI (in `FinanceView`'s body, not the controller) is your hook for letting the user pick a workspace too — check its current form.
- `AiOSCore/Sources/AiOSCore/Transport.swift` — `FetchFinanceProjectsRequest`/`FetchFinanceProjectsResponse`/`SubmitFinanceTransactionRequest` (added in slice 2) already carry a `tenant: Tenant` field that's currently unused on the Hub side. This is what you're finally putting to use.
- `AiOSHub/AiOSHub/HubController.swift` — the `financeProjects`/`submitFinanceTransaction` injected closures added in slice 2 (search for `financeCtrl` — they currently ignore `req.tenant` per slice 2's own report; find the exact current code before editing).
- `AiOSCore/Sources/AiOSCore/Tenant.swift` — confirm `Tenant`'s real cases (`.business`/`.family`, per `FinanceWorkspaceKind.tenant`'s switch) and whether it's `Codable`/`Hashable` (needed if you're keying anything by it).

---

## What to build

### 1. `FinanceProjectController` gains real tenant awareness

- `addProject(name:kind:settlementPolicy:)` and `addTransaction(to:date:description:category:direction:amount:)` should take (or derive) a real `FinanceWorkspaceScope` instead of hardcoding `.myFamily`. Simplest correct shape: add a `workspaceScope: FinanceWorkspaceScope = .myFamily` parameter to both methods (default preserves today's behavior for existing call sites in `FinanceView`'s body — check whether those call sites need an explicit picker now, or whether defaulting to `.myFamily` and adding a `.business` option later is acceptable for this slice; lean toward adding a simple workspace picker in the "Add project" UI section since it's a small, contained UI change, not a new feature).
- Filtering: `projects`/`transactions(for:)` should be filterable/queryable by `FinanceWorkspaceScope`/`Tenant`. Decide whether this means two full in-memory arrays filtered on read (simplest), or whether the persisted `FinanceSnapshot` itself should partition storage by tenant (e.g. two files, mirroring how `CaptureStore` used to be split before slice 1 unified it — **do NOT recreate that mistake**; keep ONE store, ONE file, filter in memory or by a stored field, don't re-split the persistence layer).
- `plannedBudgets` stays keyed by project id (unchanged) — a project already implies its own workspace via its `workspaceScope` field, no separate tenant key needed there.

### 2. Hub-side closures actually filter by `req.tenant`

In `HubController.swift`, the `financeProjects`/`submitFinanceTransaction` closures added in slice 2 should now filter `financeCtrl?.projects`/`.transactions` by matching `req.tenant` against each `FinanceProject.workspaceScope.tenant` (via `FinanceWorkspaceKind.tenant`), instead of returning everything regardless of tenant. `submitFinanceTransaction`'s closure should pass the request's implied workspace through to `addTransaction` (once it takes a `workspaceScope` param per §1) rather than letting it fall through to the hardcoded default.

### 3. Confirm `HubRequestRouter`/`PairedHubClient` need no changes

Slice 2 already threads `tenant: Tenant` through the request structs and into the closures. This slice's job is entirely on the Hub-controller side (§1, §2) — if you find yourself needing to change `Transport.swift`/`HubRequestRouter.swift`/`PairedHubClient.swift` beyond what slice 2 already built, stop and reconsider whether that's actually necessary before proceeding.

### 4. UI: minimal workspace picker, not a new feature

In `FinanceView`'s "Add project" section, add a simple `Picker` for `FinanceWorkspaceKind` (My Family / Business) alongside the existing `FinanceProjectKind` picker, defaulting to `.myFamily`. This is the only new UI surface this brief should add — do not build organization management, account linking, or anything else `FinanceWorkspace.swift`'s richer types support.

---

## Tests

Add to `AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift` (extend the tests slice 2 added):
- `.fetchFinanceProjects` with `tenant: .business` only returns projects whose `workspaceScope.tenant == .business`, not family-tenant projects.
- `.submitFinanceTransaction` with `tenant: .business` results in a transaction whose project association resolves correctly within the business workspace (or fails gracefully if no business project exists — check what "graceful" means given the injected-closure return type, don't invent a new error path).

If `FinanceProjectController` itself is testable in isolation (check if AiOSHub has any test target that already covers `FinanceView.swift`'s types — probably not, per the earlier review's test-coverage finding), a lightweight AiOSHub-side test is a nice-to-have, not required — AiOSCore's router-level tests are the acceptance bar.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. Manually verify (by reading the diff) that existing "My Family" projects/transactions still work exactly as before — this must be backward compatible, not a breaking change for the one thing Tim already uses (FFA is a `.youthLivestock` project, currently implicitly `.myFamily` — confirm it stays reachable and correctly scoped after this change).

---

## Acceptance criteria

1. `FinanceProjectController.addProject`/`addTransaction` no longer unconditionally hardcode `.myFamily` — a caller can specify `.business` and have it actually mean something.
2. Hub-side `.fetchFinanceProjects`/`.submitFinanceTransaction` genuinely filter by `req.tenant`, proven by test.
3. Existing "My Family" Finance data (FFA project, Valley-Perinatal-adjacent anything if present) is unaffected — verified by reading the diff and confirming defaults preserve current behavior.
4. One store, one file — persistence is NOT re-split by tenant (that would recreate the exact bug slice 1 just fixed for `CaptureStore`).
5. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
feat(index): Finance Phase 0 slice 3 — real tenant-scoping (Business vs My Family), closes slice 2's flagged gap

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (tests only, if any Transport/Router changes turn out unnecessary per §3), AiOSHub (FinanceView.swift/HubController.swift).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSHub/AiOSHub/FinanceView.swift` | AiOSHub | MODIFY — `FinanceProjectController` tenant-aware add/query, minimal workspace picker UI |
| `AiOSHub/AiOSHub/HubController.swift` | AiOSHub | MODIFY — closures actually filter by `req.tenant` |
| `AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift` | AiOSCore | MODIFY — tenant-filtering tests |
