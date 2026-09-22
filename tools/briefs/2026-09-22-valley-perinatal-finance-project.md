# CLI Brief — Index cleanup: give Valley Perinatal a real FinanceProject

**Filed:** 2026-09-22
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md`, `tools/briefs/2026-09-22-finance-objectstore-migration.md` (just-landed precedent — `FinanceProjectController` now genuinely persists through `ObjectStore`, commits AiOSCore `c570b77` / AiOSHub `36a78a5`).
**Goal:** `ValleyPerinatalConfig.projectID` is a bare string literal `"valley-perinatal"` with no backing `FinanceProject` anywhere — confirmed by an earlier review tonight. Valley Perinatal income currently can't appear in the Hub's project list, ledger, or export because it isn't actually a project in the shared model, just a local label. Fix: route it through a real `FinanceProject`, using the real `HubRequest`/`HubRequestRouter` transport already built for Finance (slices 2-3, landed tonight).

**This is different in shape from the last two Finance slices — read carefully before assuming it's the same pattern.** `FinanceProjectController` was a full migration (one Hub-local store, swap its persistence). Valley Perinatal is spoke-local data (Toggl-synced hours, deduped by `togglEntryID`) that needs to reach a Hub-authoritative project — closer to the `CaptureStore`/`FFAEntryOutbox` shape (sync from spoke to Hub over the transport) than to the pure-persistence-swap shape. Don't force it into the wrong template.

**Explicit non-goals:**
- Do NOT build a "create project from the spoke" flow — no new `HubRequest` case for creating a `FinanceProject` remotely. The natural, low-risk path: Tim (or you, once, manually, via a script/test-fixture-style seed — see step 1) creates the real "Valley Perinatal" project through the Hub's existing `FinanceView` "Add project" UI/`ObjectStore`, and `ValleyPerinatalController` *resolves* it by name via the already-built `.fetchFinanceProjects`, rather than assuming it can create one.
- Do NOT force `BillableTimeEntry` to become a `CanonicalFinancialTransaction`. It's a different lifecycle stage (logged hours, possibly unbilled) — give it its own proper `AiOSObject` conformance instead.
- Do NOT touch `MailIndex`, `EntityDecisionLedger`, `ApprovedLetterStore` — separate, later slices.
- Do NOT touch `TidyIndexObjectBridge`/`Association`/`AssociationStore` internals — consume as-is.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/Finance/BillingModels.swift` — full file. `BillableTimeEntry` (`id: String`, `financeProjectID: String`, `workspaceScope: FinanceWorkspaceScope`, `togglEntryID: Int`, plus billing/invoice fields) does NOT conform to `AiOSObject` today — no `orgID`/`scope`/`metadata`. Read `InvoiceState`, `TogglBillingSync` in the same area.
- `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalStore.swift`, `ValleyPerinatalController.swift`, `TogglFetcher.swift` — full files. `ValleyPerinatalConfig.projectID` is the hardcoded string to replace. `ValleyPerinatalStore`'s actor+JSONL pattern (dedup by `togglEntryID` via `existingTogglIDs()`) is real, working, and spoke-local — likely stays as the sync-state cache; don't retire it reflexively the way `FinanceProjects.json` was retired last slice, since this one has a genuine local-cache job (Toggl dedup) that the Hub-side store can't replace.
- `AiOSCore/Sources/AiOSCore/Transport.swift` — `FetchFinanceProjectsRequest`/`FetchFinanceProjectsResponse`, `SubmitFinanceTransactionRequest` (from slice 2 — read their exact current shape; `SubmitFinanceTransactionRequest` is transaction-shaped, likely NOT what carries a `BillableTimeEntry` — you may need a new, small `HubRequest` case for this, or determine the existing one is close enough with adaptation; make the call and justify it).
- `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` — `fetchFinanceProjects()` (added slice 2) — the method `ValleyPerinatalController` should call to resolve the real project by name.
- `AiOSHub/AiOSHub/HubController.swift` — the `financeProjects` injected closure (slice 2/3) — confirm it now reads from the real `ObjectStore`-backed `FinanceProjectController` (post the just-landed migration) rather than anything stale.
- `AiOSCore/Sources/AiOSCore/Finance/FinanceObjectMapping.swift` (just landed) — the established idiom for `AiOSObject` ↔ `ObjectInstance` encode/decode. If `BillableTimeEntry` gains `AiOSObject` conformance and gets its own `ObjectStore`-backed persistence (your call, see below), match this idiom.

---

## What to build

### 1. A real "Valley Perinatal" `FinanceProject` needs to exist

Since this brief doesn't build a remote-create flow, the pragmatic path: add a small, one-time seed — either a migration-style guarded creation (check `.fetchFinanceProjects` result for a project named "Valley Perinatal" in the business-tenant workspace; if genuinely absent after a real round-trip check, this is a signal for Tim to add it manually via `FinanceView`, not something to silently fabricate from the spoke) — **do not auto-create a `FinanceProject` from spoke-side code**, since project creation is a Hub-authoritative action per the existing architecture. If you determine a one-time Hub-side seed makes sense (e.g., in `HubController` or a migration path mirroring the just-landed Finance migration's `migrateLegacyDataIfNeeded()`), that's the right place for it, not the spoke. State clearly in your report which approach you took and why.

Tenant: `FinanceWorkspaceKind.business` (freelance work) per its own doc comment ("AiOSBusiness — company, freelance, QuickBooks history, invoices") — confirm this reads correctly against `FinanceProjectKind`'s real cases (`.freelanceEngagement` was referenced in earlier work tonight) before assuming.

### 2. `BillableTimeEntry` — real `AiOSObject` conformance

Add the missing `orgID`, `scope`, `metadata` fields (or wrap `BillableTimeEntry` in a thin `AiOSObject`-conforming envelope if adding fields directly to the existing struct is riskier — your call, but prefer direct conformance if it's a clean, additive change with sensible defaults, matching how `FinanceProject`/`CanonicalFinancialTransaction` already do it). `financeProjectID` should reference the REAL resolved project's id from step 1, not the string literal.

### 3. `ValleyPerinatalController.sync()` — resolve the real project, submit over the real transport

- Replace `ValleyPerinatalConfig.projectID` usage with a resolved lookup: call `hubClient()?.fetchFinanceProjects()`, find the business-tenant project named "Valley Perinatal" (or however Tim actually named it once seeded — check, don't assume the exact string). If not found, surface a clear `syncError` ("Valley Perinatal project not found on the Hub — add it in Finance first") rather than falling back to the old string-literal behavior silently.
- Determine the right `HubRequest` shape for submitting a `BillableTimeEntry` to the Hub — either adapt `SubmitFinanceTransactionRequest` if it's genuinely close enough, or add a new small case (`submitBillableTimeEntry`/similar) mirroring the exact pattern slice 2 established (`HubRequestRouter` injected closure, `PairedHubClient` convenience method, `HubController` wiring to a Hub-side handler). If you add a new case, keep it as small and consistent with the existing ones as possible.
- Hub-side: the submitted `BillableTimeEntry` should persist via `ObjectStore` (same pattern as `FinanceProject`/`CanonicalFinancialTransaction`, using the `AiOSObject` conformance from step 2), associated to its `FinanceProject` — decide whether that's via the `financeProjectID` property alone (simplest, matches how `CanonicalFinancialTransaction.projectAllocations` already links) or a real `Association` (per last slice's precedent) — your call, document the reasoning.
- `ValleyPerinatalStore`'s local JSONL cache stays — it's the legitimate "have I already synced this Toggl entry" dedup mechanism (`existingTogglIDs()`), a genuinely different job than Hub-side canonical storage. Don't retire it.

---

## Tests

`AiOSCore/Tests/AiOSCoreTests/HubRequestRouterTests.swift` or a new file — whatever `HubRequest` case you land on for submitting a `BillableTimeEntry`, test it the same way slice 2/3's Finance tests did: injected closure receives the right tenant + payload, a business-tenant submission can't resolve against a family-tenant (or nonexistent) project.

If `BillableTimeEntry`'s new `AiOSObject` conformance needs encode/decode mapping (per `FinanceObjectMapping.swift`'s pattern), add round-trip tests matching that file's existing style.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on all four combinations. A prior brief broke the iOS Simulator build by only testing macOS — do not repeat that.

---

## Acceptance criteria

1. Valley Perinatal resolves against a real `FinanceProject`, not a string literal — proven by test.
2. `BillableTimeEntry` has real `AiOSObject` conformance.
3. Submitted entries reach the Hub's `ObjectStore` over the real transport, tenant-correctly.
4. `ValleyPerinatalStore`'s local JSONL cache is untouched — still doing its real job (Toggl dedup), not retired.
5. A missing/unseeded project produces a clear error, not a silent fallback to the old broken behavior.
6. All four build combinations green.

---

## Commit

```
feat(index): Valley Perinatal — real FinanceProject + BillableTimeEntry over the paired-hub transport

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (BillableTimeEntry conformance, transport if a new case is added, tests), AiOSHub (HubController wiring, possible one-time seed), AiOSMyFamily (ValleyPerinatalController).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/Finance/BillingModels.swift` | AiOSCore | MODIFY — AiOSObject conformance |
| `AiOSCore/Sources/AiOSCore/Transport.swift` | AiOSCore | MODIFY (if a new HubRequest case is needed) |
| `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` | AiOSCore | MODIFY (if new case) |
| `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` | AiOSCore | MODIFY (if new case) |
| `AiOSHub/AiOSHub/HubController.swift` | AiOSHub | MODIFY — closure wiring, possible one-time seed |
| `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalController.swift` | AiOSMyFamily | MODIFY — real project resolution + submission |
