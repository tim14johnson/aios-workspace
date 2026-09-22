# CLI Brief — Universal Index, Phase 0: make CaptureStore Hub-authoritative

**Filed:** 2026-09-22
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md` — read that first for full context. This brief scopes ONLY its Phase 0.
**Goal:** Eliminate the `CaptureStore.shared` vs `CaptureStore.ffa` split that caused a real bug tonight (a weigh-in logged on one device was invisible to code reading the other partition), by making `CaptureStore` itself Hub-authoritative — the first concrete instance of "one index, universally read/write across all spokes and apps."

**Explicit non-goals for this brief:** do NOT migrate `MailIndex`, `TidyIndex`/`SpotlightIndexStore`, `FinanceProjectController`, `EntityDecisionLedger`, or any other store onto this pattern yet. Do NOT touch the dual-AI-engine unification (that's Phase 1, a separate brief, after this lands). Do NOT build the Hub→Spoke→App folder taxonomy or hotlink mechanism (Phase 4). This brief is `CaptureStore` only.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/Capture/CaptureStore.swift` — the actor to change. Currently: `CaptureStore.shared` (real default directory) is a plain local JSONL store with typed `save(_:)`/query methods per capture kind (`CapturedPhoto`, `CapturedReceipt`, `CapturedVoiceNote`, `CapturedWeight`, `CapturedLocation`, `CapturedBarcode`, `CapturedDocument`, plus whatever FFA-specific kinds were added since — check `CaptureResults.swift` for the full current list, e.g. `CapturedAnimalVisit`). `CaptureStore.ffa` is a SEPARATE instance (different directory) that `FFAIngester` writes into and `FFADashboardView` reads from — this second instance is the bug, not a real second concept.
- `AiOSCore/Sources/AiOSCore/Capture/FFAEntryOutbox.swift` — the offline-queue pattern to generalize. Actor + JSONL, `enqueue`/`pendingEntries`/`markSynced`, injectable directory for tests. This is the right shape for a spoke-side pending queue; **this brief effectively promotes this pattern from FFA-only to CaptureStore-wide.**
- `AiOSCore/Sources/AiOSCore/Finance/FFAIngester.swift` — the Hub-side ingestion pattern to generalize. `actor FFAIngester`, `ingest(_ entry: FFAPendingEntry) async`, dispatches by payload case into `CaptureStore.ffa.save(...)`. **This brief generalizes this into ingesting ANY CaptureStore payload kind, not just FFA's four.**
- `AiOSCore/Sources/AiOSCore/Transport.swift` — `HubRequest`/`HubReply` enums. Already has `.submitFFAEntry(FFAPendingEntry)` → `.ffaEntryAcknowledged`, added for the FFA case specifically. **Read this whole file** — you're adding a more general case here.
- `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` — Hub-side pure dispatch, `func handle(_ request: HubRequest) async -> HubReply`. Has the `.submitFFAEntry` arm as your pattern to follow (direct actor call, no injected closure needed, since the target is a global actor).
- `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` — spoke-side client, has `submitFFAEntry(_:)` as your pattern to follow for a new, more general method.
- `AiOSMyFamily/AiOSMyFamily/SpokeController.swift` and `AiOSBusiness/AiOSBusiness/SpokeController.swift` — both have `hubClient() -> PairedHubClient?` already. `submitFFAEntry(_:)` (AiOSMyFamily only currently) is the pattern for a general `submitCapture(_:)`.
- `AiOSCore/Sources/AiOSCore/SpotlightDiscoverer.swift` (macOS-only, `#if os(macOS)`) — has `financeExtensions`/`financeFinderTags`/`discoverTaggedFinanceFiles()`. This is your Spotlight pre-fill hook for step 4 below — start with receipts only, since the extension/tag machinery already matches receipt-shaped files (PDFs, images with finance-adjacent Spotlight tags).

---

## What to build

### 1. `CaptureRecord` envelope — a generic wire-transport wrapper, AiOSCore

Do NOT try to collapse `CapturedPhoto`/`CapturedReceipt`/etc. into one polymorphic Swift type — that's a bigger refactor than this brief needs and would touch every call site. Instead, add a thin envelope enum mirroring `FFAPendingEntryPayload`'s exact shape, covering every existing `CaptureStore` payload kind:

```swift
public enum CaptureRecordPayload: Sendable, Codable, Equatable {
    case photo(CapturedPhoto)
    case receipt(CapturedReceipt)
    case voiceNote(CapturedVoiceNote)
    case weight(CapturedWeight)
    case location(CapturedLocation)
    case barcode(CapturedBarcode)
    case document(CapturedDocument)
    // Add any other existing CapturedX kind found in CaptureResults.swift — check before assuming
    // this list is complete, it was accurate as of Phase 0's filing but the capture suite has grown.
}

public struct CaptureRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let payload: CaptureRecordPayload
    public let sourceDeviceID: String   // which device captured this — for provenance, not access control
    public let queuedAt: Date
    public var synced: Bool
}
```

### 2. Promote `FFAEntryOutbox`'s pattern to a general `CaptureOutbox`, AiOSCore

New file `AiOSCore/Sources/AiOSCore/Capture/CaptureOutbox.swift` — same actor+JSONL shape as `FFAEntryOutbox` (injectable directory, `.shared` real default), holding `CaptureRecord`s: `enqueue(_:)`, `pendingEntries() async -> [CaptureRecord]`, `markSynced(id:) async`. Do NOT delete `FFAEntryOutbox` yet — FFA's spoke UI still calls it directly for now; a follow-up brief can retire it once `CaptureOutbox` is proven. (This brief is additive, not a rip-and-replace.)

### 3. Wire transport — `HubRequest`/`HubReply`, generalized

In `Transport.swift`, add:
```swift
case submitCapture(CaptureRecord)
// reply:
case captureAcknowledged
```

In `HubRequestRouter.swift`, add the dispatch arm — this is where `CaptureStore.ffa` gets retired as a concept. The Hub-side store IS `CaptureStore.shared` now (there is only one, and it's Hub-authoritative):
```swift
case .submitCapture(let record):
    switch record.payload {
    case .photo(let p): try? await CaptureStore.shared.save(p)
    case .receipt(let r): try? await CaptureStore.shared.save(r)
    case .voiceNote(let v): try? await CaptureStore.shared.save(v)
    case .weight(let w): try? await CaptureStore.shared.save(w)
    case .location(let l): try? await CaptureStore.shared.save(l)
    case .barcode(let b): try? await CaptureStore.shared.save(b)
    case .document(let d): try? await CaptureStore.shared.save(d)
    }
    return .captureAcknowledged
```

In `PairedHubClient.swift`, add `submitCapture(_ record: CaptureRecord) async throws { _ = try await send(.submitCapture(record)) }`.

### 4. Retire the `.ffa` partition — this is the actual bug fix, generalized

- In `CaptureStore.swift`, remove the `.ffa` static instance entirely (or leave it as a deprecated alias pointing at `.shared`, your call, but nothing should write to a second partition going forward).
- Update `FFAIngester.ingest(_:)` to write into `CaptureStore.shared` directly (it already does the same per-payload-kind switch this brief's `HubRequestRouter` arm does — consider whether `FFAIngester` should just become a thin wrapper calling the same logic, or whether `.submitFFAEntry`/`FFAIngester` should be retired in favor of the new general `.submitCapture` path now that it exists. Lean toward retiring `.submitFFAEntry` if `FFAPendingEntry`'s four payload kinds are a strict subset of `CaptureRecordPayload`'s — don't keep two transport paths for the same data if one now strictly supersedes the other. If you retire it, update `FFACaptureSection.swift`'s `sendToHub`/`submitFFAEntry` call site to use the new `submitCapture` client method instead, and update the AiOSCore tests accordingly (`FFATests.swift`, `HubRequestRouterTests.swift` — the ones fixed earlier today to assert against `CaptureStore.ffa` will need a further update to assert against `.shared` again, since `.ffa` is going away).
- `AiOSHub/AiOSHub/FFADashboardView.swift` and `AiOSHub/AiOSHub/FinanceView.swift` (both currently reading `CaptureStore.ffa` / `CaptureStore.shared` respectively, per tonight's fix) should both end up reading the same `CaptureStore.shared` — confirm both actually do after this change; this IS the fix this whole brief exists to generalize.

### 5. Spotlight pre-fill — one kind, to prove the mechanism, not all seven

Add a method to `CaptureStore` (or a small standalone helper) that, on Hub startup (or via an explicit refresh action — your call, keep it simple), calls `SpotlightDiscoverer.discoverTaggedFinanceFiles()` (macOS-only, already `#if os(macOS)`-gated at its source) and seeds `CapturedReceipt` records for any discovered file not already present (dedupe by file path or content hash — check what `FileRecord`/`SpotlightResult` actually expose before designing the dedupe key). This is the concrete first instance of point 1.1 ("leverage the Spotlight index... to pre-fill its deeper and more personally contextualized database") — scoped to receipts only, since the tag/extension machinery already exists for that kind. Do not attempt to Spotlight-prefill photos/documents/voice notes/etc. in this brief.

---

## Tests

Add to `AiOSCore/Tests/AiOSCoreTests/CaptureTests.swift` (or a new `CaptureOutboxTests.swift`, match whatever's cleaner given the existing file's size):
- `CaptureOutbox` enqueue → pendingEntries → markSynced round trip (mirror `FFAEntryOutboxTests`'s existing shape).
- `HubRequestRouter.handle(.submitCapture(...))` for at least two different payload kinds (not just weight) returns `.captureAcknowledged` and the record reaches `CaptureStore.shared`.
- If `FFAIngester`/`.submitFFAEntry` is retired: confirm its removal doesn't break anything still depending on it (grep first).
- Spotlight pre-fill: at minimum, a test confirming a discovered file doesn't get double-inserted on a second call (idempotent).

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on BOTH platforms for both spoke apps (a prior brief broke iOS Simulator by missing this — don't repeat that).

---

## Acceptance criteria

1. `CaptureStore.ffa` no longer exists as a separate partition — there is one `CaptureStore.shared`, and everything (FFA included) reads/writes it.
2. A weight (or any capture kind) submitted via the new `.submitCapture` `HubRequest` path is visible to both `FFADashboardView` and `FinanceView` without any code-level knowledge of which device originated it.
3. Spotlight pre-fill for receipts is real and idempotent (verified by test, not just "it compiles").
4. All builds green on macOS AND iOS Simulator for both spoke apps.
5. `docs/architecture/2026-09-22-back-to-basics-review.md`'s Phase 0 checkbox can honestly be marked done after this lands — if you find yourself cutting a corner to make that true, don't cut it silently; report the gap instead.

---

## Commit

```
feat(index): CaptureStore Phase 0 — retire .ffa partition, Hub-authoritative via HubRequest, Spotlight prefill for receipts
```

Repos touched: AiOSCore (CaptureRecord/CaptureOutbox/Transport/HubRequestRouter/PairedHubClient/CaptureStore), AiOSMyFamily (FFACaptureSection.swift call-site update if `.submitFFAEntry` is retired), AiOSHub (confirm FFADashboardView/FinanceView both read `.shared`).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/Capture/CaptureRecord.swift` | AiOSCore | CREATE (or fold into CaptureResults.swift, your call) |
| `AiOSCore/Sources/AiOSCore/Capture/CaptureOutbox.swift` | AiOSCore | CREATE |
| `AiOSCore/Sources/AiOSCore/Capture/CaptureStore.swift` | AiOSCore | MODIFY — retire `.ffa`, add Spotlight prefill |
| `AiOSCore/Sources/AiOSCore/Transport.swift` | AiOSCore | MODIFY — add `.submitCapture`/`.captureAcknowledged` |
| `AiOSCore/Sources/AiOSCore/HubRequestRouter.swift` | AiOSCore | MODIFY — dispatch arm |
| `AiOSCore/Sources/AiOSCore/PairedHubClient.swift` | AiOSCore | MODIFY — `submitCapture(_:)` |
| `AiOSCore/Sources/AiOSCore/Finance/FFAIngester.swift` | AiOSCore | MODIFY or RETIRE (decide during build, per §4) |
| `AiOSMyFamily/AiOSMyFamily/FFACaptureSection.swift` | AiOSMyFamily | MODIFY — call-site update if `.submitFFAEntry` retired |
| `AiOSHub/AiOSHub/FFADashboardView.swift`, `FinanceView.swift` | AiOSHub | VERIFY both read `.shared` post-change |
