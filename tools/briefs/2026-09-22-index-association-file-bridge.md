# CLI Brief — Index Phase 0, Step 2-4: real Associations + File objects + unified Spotlight donation

**Filed:** 2026-09-22
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md`, `docs/architecture/2026-09-22-spotlight-schema-mapping.md` (read both — this brief implements steps 2-4 of that doc's "what this actually recommends building" section).
**Goal:** Close the two concrete, verified gaps from tonight's review: (1) there is no real `Association` type, only embedded `PropertyValue.reference` pointers — not a queryable graph; (2) `TidyIndexEntry` (Tidy Files' proven, working file index) and `ObjectStore`/`ObjectInstance` (the generic, cross-domain entity graph) never talk to each other, so a file Tidy Files already knows about has no relationship in the graph to any Person/Organization/Project.

**Explicit non-goals — read before starting:**
- Do NOT build content-based entity extraction (NLP/AI reading file text to find company/person names). This brief is **path-based only** — `TidyIndexEntry.assignment: SchemaAssignment?` already carries organization/category/project classification from the existing schema classifier; that's the only signal this brief uses. Content-based extraction (generalizing `EmailListingExtractor`/`JDThemeExtractor`-style logic) is real future work, scoped separately, once this foundation exists.
- Do NOT touch `CaptureStore`, `FinanceProjectController`, or any of tonight's earlier Index Phase 0 slices (1-3, already landed and pushed).
- Do NOT build any new UI to browse the graph. This is pure data-layer work.
- Do NOT migrate `ObjectStore`'s persistence to SQLite. Still premature per the review doc's own sequencing (only justified once file-scale data is actually flowing through it — this brief is what makes that true for the first time, but the migration itself is later work).

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/ObjectStore.swift`, `ObjectInstance.swift`, `CanonicalObject.swift` — the generic entity store. Read fully (all three are short). `ObjectStore.upsert(_:)`, `.all(type:)`, `.get(_:)`. `ObjectInstance` has `id`, `type: AiOSObjectType`, `properties: [String: PropertyValue]`, `start`/`end`, `recordedAt`. `PropertyValue` has `.reference(ObjectRef)` — the thing this brief's new `Association` type supersedes for cross-object links (leave `.reference` in place for other uses, just don't use it for the new File↔Organization/Project links this brief creates).
- `AiOSCore/Sources/AiOSCore/TidyIndex.swift` — `TidyIndexEntry` (content-hash identity, `currentLocations`, `assignment: SchemaAssignment?`, `tags: [String]`). Read the full file, including whatever actor/store wraps it (search for where `TidyIndexEntry` gets persisted — likely a `TidyIndex` actor in the same file).
- `AiOSCore/Sources/AiOSCore/DestinationSchema.swift` — `SchemaLevel` (`.organization`, `.subOrganization`, `.persons`, `.category`, `.project`, `.subProject`, `.fileType`, `.dateFolder`) and `SchemaAssignment` (`values: [String: String]` keyed by `SchemaLevel.rawValue`, subscriptable by `SchemaLevel`). This is your path-based classification source — `assignment[.organization]`, `assignment[.category]`, `assignment[.project]`.
- `AiOSCore/Sources/AiOSCore/Citation.swift` — `Citation` (`id`, `signalID`, `source: SpokeID`, `field: String?`, `snippet`). Currently only attaches to `Signal`. Check whether it's reasonable to reuse as-is for Association provenance (an Association "citing" the `TidyIndexEntry`/classification event that created it) or whether that's a stretch — report your judgment, don't force it if the fit is bad.
- `AiOSCore/Sources/AiOSCore/SpotlightDonationService.swift` — the generic, currently-uncalled `ObjectInstance` → Spotlight donation path (`donate(_:)`/`revoke(_:)` via `CSSearchableIndex`).
- `AiOSHub/AiOSHub/TidySpotlightDonor.swift` — the duplicate, `TidyIndexEntry`-specific donation path that's actually wired in and working today. Read `OrganizerController.swift` (or wherever it's called from) to find the real call site before touching it.
- `AiOSCore/Sources/AiOSCore/EntityDecisionLedger.swift` and `BlueprintEntityIntake.swift` — the existing consumers of `ObjectStore`/`ObjectInstance` (Job Seeker's contact/company resolution). Read these for the established idiom of constructing `ObjectInstance`s and their `canonicalID` convention (`"org:acme"`/`"person:tim johnson"`) — your new File-bridge code should follow the same idiom, not invent a different one.
- `docs/ontology-strawman.md` §2.3 — the `Association` primitive's intended shape (`id`, `fromID`/`toID`, `type`, `validFrom`/`validTo`, `citations`). This is your target shape — implement it for real, don't approximate with something smaller.

---

## What to build

### 1. A real `Association` type + `AssociationStore`, AiOSCore

New file `AiOSCore/Sources/AiOSCore/Association.swift`:
```swift
/// A typed, directional, time-bounded link between two objects — the ontology's Association
/// primitive, finally implemented for real (PropertyValue.reference was always a weaker stand-in).
public struct Association: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let fromID: String
    public let fromType: AiOSObjectType
    public let toID: String
    public let toType: AiOSObjectType
    public let type: String          // e.g. "located_in", "belongs_to", "member_of" — open string, mirrors AiOSObjectType's own openness
    public let validFrom: Date
    public var validTo: Date?        // nil = still live
    public var citationIDs: [UUID]   // references into Citation records, if/where that fit is reasonable per your judgment above
}
```
(Adjust field names/types if something cleaner emerges once you've read `ObjectRef`/`AiOSObjectType`'s real conventions — the shape above is the target, not a literal mandate.)

New file `AiOSCore/Sources/AiOSCore/AssociationStore.swift` — actor, mirror `ObjectStore`'s exact persistence pattern (one JSON map per tenant, `applicationSupport(tenant:)` convenience, `upsert`/`all`/`get`). Add a query method for "everything associated with object X" (`func associations(for objectID: String) -> [Association]`) — this is the whole point, a File object needs to answer "what am I linked to."

### 2. `File` as a real `AiOSObjectType`, and the `TidyIndexEntry` → `ObjectInstance` + `Association` bridge

New file `AiOSCore/Sources/AiOSCore/TidyIndexObjectBridge.swift` (or fold into `TidyIndex.swift` if that reads cleaner — your call):

- Define `AiOSObjectType` constants for `"File"`, `"Organization"`, `"Project"` if they don't already exist as shared constants somewhere (check `BlueprintEntityIntake.swift`/`EntityDecisionLedger.swift` first — they likely already use `"Organization"`, reuse it, don't redefine).
- A function `bridge(_ entry: TidyIndexEntry, into objectStore: ObjectStore, associations: AssociationStore) async throws` that:
  - Only acts when `entry.assignment != nil` and `assignment.isComplete(for:)` (or at minimum has organization+category+project — use your judgment on the completeness bar, but don't create garbage Associations from partial/needs-review classifications).
  - Upserts a `File`-typed `ObjectInstance` for the entry (id derived from `entry.contentHash`, properties: `path` = first of `currentLocations`, `name` = `originalName`, `tags` = entry.tags mapped to `PropertyValue.list`).
  - Resolves (or creates, if not found — using the same `canonicalID` convention `BlueprintEntityIntake` already uses) an `Organization`-typed `ObjectInstance` for `assignment[.organization]`, and a `Project`-typed `ObjectInstance` for `assignment[.project]`.
  - Creates (or updates `validTo`/renews) `Association`s: File `belongs_to` Organization, File `part_of` Project (pick your own type-string names, or match the ontology doc's `parent_of` convention if it fits better — explain your choice in the report).
- Call this bridge from wherever `TidyIndexEntry`s actually get their `assignment` set during the night crawl (`OrganizerController.runNightPass()` or wherever `SchemaClassifier` output gets written back) — find the real call site, don't guess. This should run automatically as part of the existing crawl, not require a separate manual trigger.

### 3. Unify Spotlight donation — one path, not two

- Retire `AiOSHub/AiOSHub/TidySpotlightDonor.swift`'s separate donation logic. The bridge from step 2 already produces a `File`-typed `ObjectInstance` for every classified file — route Spotlight donation through the existing, generic `SpotlightDonationService.donate(_:)` on that `ObjectInstance` instead of maintaining a second, `TidyIndexEntry`-specific donation path.
- Find and update the real call site (wherever `TidySpotlightDonor.donate(entries:)` is currently invoked) to call `SpotlightDonationService` instead, or to call the bridge (which internally donates) — whichever keeps the call site simplest. Don't leave both paths active.
- If `TidySpotlightDonor.swift` ends up with nothing left in it, delete the file — don't leave a dead file behind. If some Tidy-Files-specific behavior in it (e.g. `NSUserActivity`/`CSSearchableItemActionType` handling for tap-through) is real and worth keeping, keep exactly that part and remove only the duplicate donation logic.

---

## Tests

`AiOSCore/Tests/AiOSCoreTests/AssociationStoreTests.swift` (new):
- Upsert/get/all round trip.
- `associations(for:)` returns associations where the object is either `fromID` or `toID` (or just `fromID`, if you decide the query should be directional-only — state which and why).
- A closed (`validTo` set) association is still retrievable but distinguishable from a live one.

`AiOSCore/Tests/AiOSCoreTests/TidyIndexObjectBridgeTests.swift` (new):
- A `TidyIndexEntry` with a complete `assignment` produces a `File` `ObjectInstance` in `ObjectStore` and two `Association`s (to Organization, to Project) in `AssociationStore`.
- An entry with an incomplete/nil `assignment` produces nothing (no garbage objects).
- Running the bridge twice on the same entry doesn't duplicate the File object or the Associations (idempotent — check by content hash / canonical id, not by blindly appending).
- Two different files under the same organization/project resolve to the *same* Organization/Project `ObjectInstance`, not two separate ones (this is the actual point of the bridge — proves cross-file entity resolution works).

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings.

---

## Acceptance criteria

1. Real `Association` type exists with `AssociationStore` persistence, matching the ontology's documented shape (directional, typed, time-bounded).
2. A classified `TidyIndexEntry` produces a real `File` `ObjectInstance` plus real `Association`s to Organization/Project objects — proven by test, and proven to be idempotent and cross-file-deduplicating.
3. Exactly one Spotlight donation path exists, not two — `TidySpotlightDonor`'s duplicate logic is gone (file deleted or reduced to only its non-duplicate parts).
4. This runs automatically as part of the existing night crawl, not as a separate manual step.
5. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
feat(index): real Association type + TidyIndexEntry→ObjectStore bridge, unify Spotlight donation

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (Association/AssociationStore/bridge/tests), AiOSHub (OrganizerController call site, TidySpotlightDonor retirement).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/Association.swift` | AiOSCore | CREATE |
| `AiOSCore/Sources/AiOSCore/AssociationStore.swift` | AiOSCore | CREATE |
| `AiOSCore/Sources/AiOSCore/TidyIndexObjectBridge.swift` | AiOSCore | CREATE |
| `AiOSCore/Tests/AiOSCoreTests/AssociationStoreTests.swift` | AiOSCore | CREATE |
| `AiOSCore/Tests/AiOSCoreTests/TidyIndexObjectBridgeTests.swift` | AiOSCore | CREATE |
| `AiOSHub/AiOSHub/OrganizerController.swift` | AiOSHub | MODIFY — call the bridge after classification |
| `AiOSHub/AiOSHub/TidySpotlightDonor.swift` | AiOSHub | MODIFY or DELETE — retire duplicate donation logic |
