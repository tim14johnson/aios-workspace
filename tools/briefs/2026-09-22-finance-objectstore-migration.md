# CLI Brief — Index cleanup: migrate FinanceProjectController onto the real ObjectStore

**Filed:** 2026-09-22
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md`, `tools/briefs/2026-09-22-index-association-file-bridge.md` (the just-landed precedent — `TidyIndexEntry`→`ObjectStore` bridge, commits `3cac7bf`/`a785ddf`).
**Goal:** `FinanceProject`/`CanonicalFinancialTransaction` already conform to `AiOSObject` — but `FinanceProjectController` persists them in its own bespoke `FinanceProjects.json` snapshot file, a knowing duplication its own code comment admits ("the same 'load whole, save whole' shape `ObjectStore` uses for its own"). This is exactly the "separate store per vertical" pattern Tim flagged as the real risk tonight. Retire the duplication: `ObjectStore` becomes the actual persistence, not just a shape it happens to resemble.

**This is a full migration, not an additive bridge — different from how the TidyIndex work landed.** `TidyIndexEntry` kept its own specialized store (content-hash dedup, move lineage — real needs a generic property bag doesn't serve well) and got an *additional* `ObjectInstance` mirror for cross-referencing. `FinanceProject`/`CanonicalFinancialTransaction` don't have that kind of specialized need — they're genuinely entity-shaped, already `AiOSObject`-conforming, and keeping a separate `FinanceProjects.json` alongside an `ObjectStore` mirror would just be a second copy, not a fix. Retire `FinanceProjects.json` entirely; `ObjectStore` is the only persistence after this lands.

**Explicit non-goals:**
- Do NOT change `FinanceView.swift`'s UI code or `FinanceProjectController`'s public method signatures/types (`projects`, `transactions(for:)`, `addProject(...)`, `addTransaction(...)`, `setPlannedBudget(...)`, `plannedBudget(for:)`) — callers keep working with typed `FinanceProject`/`CanonicalFinancialTransaction` structs exactly as today. Only the persistence *implementation* changes.
- Do NOT touch `ValleyPerinatalStore` or wire it to `FinanceProject` in this brief — flagged as a real, separate follow-on (Valley Perinatal income currently has no backing `FinanceProject` at all), but out of scope here.
- Do NOT touch `MailIndex`, `EntityDecisionLedger`, `ApprovedLetterStore`, `SessionStore`, `HealthIndex` — separate, later slices with genuinely different shapes (see the companion review doc).
- Do NOT change `ObjectStore`/`ObjectInstance`/`Association`/`AssociationStore` themselves — consume as-is, they're proven and tested from tonight's earlier work.

---

## What already exists — read before writing anything

- `AiOSHub/AiOSHub/FinanceView.swift` — `FinanceProjectController` (full class — search for it, it may have shifted position after multiple edits tonight), `FinanceSnapshot` (the struct being retired), and every call site of `projects`/`transactions`/`addProject`/`addTransaction`/`setPlannedBudget`/`plannedBudget(for:)` in the rest of the file (the UI code — confirm none of it needs to change).
- `AiOSCore/Sources/AiOSCore/Finance/FinanceProject.swift` — real field list: `id, orgID, scope, metadata, workspaceScope, name, kind, status, description, startDate, expectedEndDate, actualEndDate, clientName, agreementReference, invoiceNumberPrefix, currentRateID, weeklyAllocationID, settlementPolicy, taxSupportRequired, taxNotes`. Read the full init.
- `AiOSCore/Sources/AiOSCore/Finance/CanonicalFinancialTransaction.swift` — real field list (per tonight's slice 2/3 work: `id, orgID, scope, metadata, workspaceScope, primaryAccountID, transactionDate, amount, direction, transactionType, rawPayee, normalizedDescription, primaryCategoryID, projectAllocations`). Read the full init.
- `AiOSCore/Sources/AiOSCore/ObjectStore.swift`, `ObjectInstance.swift`, `CanonicalObject.swift` — full files (short, already read once tonight, re-confirm current state). `ObjectInstance` stores a generic `properties: [String: PropertyValue]` bag — `PropertyValue` has `.text`, `.number`, `.money(Decimal)`, `.date`, `.boolean`, `.reference(ObjectRef)`, `.list`.
- `AiOSCore/Sources/AiOSCore/TidyIndexObjectBridge.swift` (just landed) — the established idiom for converting a domain type's fields into `ObjectInstance.properties`, and for resolving/creating related objects via `canonicalID`. Match this idiom for the encode/decode direction, don't invent a different one.
- `AiOSHub/AiOSHub/HubController.swift` — `financeController` property and the injected `financeProjects`/`submitFinanceTransaction` closures (tonight's slice 2/3) — confirm these still work correctly once the controller's internal persistence changes; they read `financeCtrl?.projects`/`.transactions(forTenant:)`, which are public API this brief must not change the shape of.

---

## What to build

### 1. Encode/decode: `FinanceProject`/`CanonicalFinancialTransaction` ↔ `ObjectInstance`

Two functions (as extensions, or free functions in a new small file — your call), each direction:
- `FinanceProject` → `ObjectInstance`: `id` stays the same, `type = AiOSObjectType("FinanceProject")` (check whether a shared constant for this already exists in `BaseObjects.swift` per the "check first" instruction the last brief established — reuse if present, define if not), `properties` carries every field that isn't part of `AiOSObject`'s own envelope (`name`, `kind.rawValue`, `status.rawValue`, `description`, dates, `clientName`, etc. — map each to the appropriate `PropertyValue` case). `settlementPolicy` is a nested struct — encode it as JSON text in a single Property if that's cleaner than exploding every field, your call, just document the choice.
- `ObjectInstance` → `FinanceProject`: the reverse. Fail gracefully (return nil / throw, your choice, document it) on a malformed/incomplete instance rather than crashing.
- Same pair for `CanonicalFinancialTransaction` ↔ `ObjectInstance` (type `"CanonicalFinancialTransaction"`).
- **`plannedBudgets`**: currently a separate `[String: Decimal]` dict in `FinanceProjectController` because `FinanceProject` has no budget field of its own. Now that persistence goes through `ObjectInstance`'s free-form `properties` bag, fold it in as an extra Property on the Project's `ObjectInstance` (e.g. `properties["plannedBudget"] = .money(amount)`) instead of maintaining a separate file/dict — this was a workaround for the old rigid-struct persistence, and it goes away naturally with this migration. Confirm `setPlannedBudget`/`plannedBudget(for:)`'s existing signatures still work unchanged from the caller's perspective.

### 2. `FinanceProjectController`'s internals — swap the persistence layer

- Replace `load()`/`persist()`/`storeURL`/`FinanceSnapshot` with calls to `ObjectStore` (`.all(type:)`, `.upsert(_:)`, `.get(_:)`) via the encode/decode functions from step 1.
- `init(storeURL: URL? = nil)` — check whether this parameter is used by tests or only ever called with the default; if only ever default, consider whether it should become `init(objectStore: ObjectStore = .applicationSupport(tenant: /* whichever tenant the controller already defaults to */))` instead, matching `ObjectStore`'s own construction pattern. If the existing `storeURL` parameter is load-bearing for tests, keep a compatible injection point — don't break test isolation.
- `projects`/`transactions` (the in-memory arrays the UI reads) can stay as cached arrays refreshed from `ObjectStore` on load/mutation — no need to make every UI-facing read `async` if the current synchronous `@Observable` shape is worth preserving; use your judgment on whether `ObjectStore`'s actor isolation forces some methods to become `async` (it likely does, since `ObjectStore` is an actor) and thread that through the UI call sites cleanly if so — check what changes are actually required by the compiler, don't guess.

### 3. Delete the old store

Once migrated, delete `FinanceSnapshot`'s persistence path entirely (`FinanceProjectController.defaultStoreURL()` and the old JSON file logic) — don't leave a dead, unused file-writing path behind. If there's real existing data in `~/Library/Application Support/AiOS/FinanceProjects.json` on this machine (check), decide whether a one-time migration-on-first-load makes sense (read the old file if `ObjectStore` is empty, upsert its contents, then never touch the old file again) versus just starting fresh — given this is Tim's real FFA project data, a one-time migration read is the safer choice; don't silently drop existing data.

---

## Tests

`AiOSHub` currently has no test coverage for `FinanceProjectController` (confirmed by an earlier review tonight) — this brief doesn't need to fix that gap generally, but DO add focused coverage for the migration itself if there's a reasonable place to put it (check whether AiOSHub has any test target at all that could exercise this, or whether the encode/decode functions could live in AiOSCore instead — where there IS real test infrastructure — with `FinanceProjectController` in AiOSHub just calling them). If the encode/decode logic can cleanly live in `AiOSCore/Sources/AiOSCore/Finance/` instead of `AiOSHub/AiOSHub/FinanceView.swift`, prefer that — it's more testable there and keeps AiOSHub thin. Add tests to `AiOSCore/Tests/AiOSCoreTests/FFATests.swift` or a new `FinanceObjectMappingTests.swift`:
- Round-trip: `FinanceProject` → `ObjectInstance` → `FinanceProject` preserves all fields.
- Round-trip for `CanonicalFinancialTransaction`.
- `plannedBudget` round-trips correctly as a Property.
- A malformed `ObjectInstance` (missing a required field) decodes to nil/throws rather than crashing.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. Manually verify by reading the diff that `FinanceView.swift`'s actual UI/interaction code is untouched — this must be a pure persistence-layer swap, invisible to the user. If real existing data exists in the old `FinanceProjects.json`, verify (by reading the migration code path, not just assuming) that it survives the switch.

---

## Acceptance criteria

1. `FinanceProjectController` persists through `ObjectStore` — `FinanceProjects.json`/`FinanceSnapshot` no longer exist as a separate store.
2. `FinanceView.swift`'s UI code is unchanged — this is invisible to the user.
3. `plannedBudgets` folds into the Project's own `ObjectInstance` properties instead of a separate dict/file.
4. Existing real data (if any) survives the migration — not silently dropped.
5. Round-trip encode/decode tests pass for both `FinanceProject` and `CanonicalFinancialTransaction`.
6. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
feat(index): migrate FinanceProjectController persistence onto ObjectStore, retire the duplicate store

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (encode/decode functions + tests, if placed there per step 1/tests guidance), AiOSHub (`FinanceView.swift`'s `FinanceProjectController` internals).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/Finance/FinanceObjectMapping.swift` (or similar) | AiOSCore | CREATE — encode/decode functions, if placed here per the tests-placement guidance |
| `AiOSCore/Tests/AiOSCoreTests/FinanceObjectMappingTests.swift` | AiOSCore | CREATE |
| `AiOSHub/AiOSHub/FinanceView.swift` | AiOSHub | MODIFY — `FinanceProjectController` internals only |
