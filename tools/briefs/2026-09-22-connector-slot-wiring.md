# CLI Brief — Library, first slice: wire the real ConnectorSlot/BlueprintConfiguration checkout mechanism

**Filed:** 2026-09-22
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 2 section — this is the "smallest real first slice" scoped there.
**Priority context:** Tim's stated order is Index (now landed through Valley Perinatal, five slices deep) → **Library** → dual-engine unification. This is the first Library slice.

**Goal:** `ConnectorSlot`/`BlueprintConfiguration` (`AiOSCore/Sources/AiOSCore/ConnectorSlot.swift`) is a real, already-designed, already-unit-tested "checkout" abstraction for connectors — exactly what point 1.7 of the vision ("library of models/tools/connectors... an orchestrator checks out from") describes, at least for the connector third of it. It has never been wired to a real consumer, and — a bigger gap found while scoping — **no real `Blueprint` in the codebase populates `connectorSlots` at all today**, so there's nothing real to resolve against even if `SpokeController` called it. This is the exact "`ObjectStore` before tonight" shape: a real, tested primitive with zero live callers. Make it real, on one concrete vertical, end to end.

**Explicit non-goals:**
- Do NOT build a settings UI for editing `BlueprintConfiguration`/re-wiring slots. A sensible default configuration (empty `slotWiring`, meaning every slot falls back to the Blueprint's own shipped `activeConnectorID`) is enough to prove the mechanism for real. Per-tenant override already works for free once this lands (`BlueprintConfiguration.slotWiring` exists and is tested) — building UI to edit it is a separate, later increment.
- Do NOT touch `ConnectorRegistry.swift` — that's a different, unrelated thing (an onboarding catalog of which desktop apps are connectable, not a runtime dispatcher). Don't conflate the two.
- Do NOT build the model-checkout half of the Library (no `ModelProfile`/`ModelDescriptor` type). That's flagged as the deliberately separate, higher-design-risk second slice in the roadmap doc — sequencing matters, don't combine them.
- Do NOT change `SpokeConnector`'s protocol shape, or any concrete connector's (`PhotoLibraryConnector`/`SystemHealthConnector`/etc.) internals — consume `connectorID` as-is.
- Do NOT touch `AiOSMyFamily`'s `SpokeController`/connectors beyond whatever minimal change is needed to keep it building — this slice's real target is `AiOSBusiness` (see below); AiOSMyFamily should end this slice behaviorally unchanged (still fires every injected connector, since it has no matching Blueprint yet — that's fine and correctly out of scope here).

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/ConnectorSlot.swift` — full file, already read once tonight during scoping. `ConnectorType` enum, `ConnectorSlot{slotID, acceptedTypes, defaultFieldMappings, isRequired, activeConnectorID}`, `BlueprintConfiguration{blueprintName, slotWiring}` with `activeConnectorID(forSlot:in:) -> String?` (checks `slotWiring` override first, falls back to the Blueprint's own shipped default, else `nil`/unwired).
- `AiOSCore/Tests/AiOSCoreTests/ConnectorSlotTests.swift` — existing passing tests for the type itself, in isolation. Read it to understand the intended usage idiom before writing new call sites.
- `AiOSCore/Sources/AiOSCore/Blueprint.swift` — `Blueprint.connectorSlots: [ConnectorSlot]` (line 111), part of the full `Blueprint` struct — read the whole struct, understand what else it carries (it's a vertical's synced definition, separate from a tenant's runtime `BlueprintConfiguration`).
- `AiOSCore/Sources/AiOSCore/JobSeekerBlueprint.swift` — the real, live Job Seeker Blueprint. **Confirmed via grep tonight: `connectorSlots` is not populated here at all** — this is the gap. Read the full init to see exactly how to add slots consistent with however this Blueprint constructs its other fields.
- `AiOSBusiness/AiOSBusiness/AiOSBusinessApp.swift` — the real, live connector injection for Job Seeker's spoke: `SpokeController(tenant: .business, connectors: [PhotoLibraryConnector(spokeID: .business, ledger: ...), SystemHealthConnector(spokeID: .business)])`. Confirmed real `connectorID` values: `PhotoLibraryConnector.connectorID == "photo-library"` (`PhotoLibraryConnector.swift:119`), `SystemHealthConnector.connectorID == "system-health"` (`SystemHealthConnector.swift:12`). These are the two connectors this slice's Blueprint slots should describe.
- `AiOSBusiness/AiOSBusiness/SpokeController.swift` — mirror of the `AiOSMyFamily` one (same file structure, confirmed near-identical): `private let connectors: [any SpokeConnector]` injected at init, `gatherSignals()` (near the bottom of the file) iterates `connectors` unconditionally, calling `.fetch()` on every one, best-effort. This is the loop to make slot-aware.
- `AiOSCore/Sources/AiOSCore/SpokeConnector.swift` — the protocol itself: `connectorID: String`, `domainIdentifier`, `fetch() -> ConnectorOutput`. Read in full.

---

## What to build

### 1. Give `JobSeekerBlueprint` real `connectorSlots`

Add two `ConnectorSlot`s matching what `AiOSBusinessApp` already injects: one for `.photoLibrary` (`slotID` your call — something like `"photo-library"`, `acceptedTypes: [.photoLibrary]`, `activeConnectorID: "photo-library"`), one for system health (`ConnectorType` has no dedicated case for this — use `.custom("systemHealth")` or similar, your call, document it since this is the first real use of `.custom`; `activeConnectorID: "system-health"`). `isRequired` — your call based on whether Job Seeker's actual behavior today treats either connector as load-bearing (check `gatherSignals()`'s current best-effort/never-fails posture — it looks like neither is required today, so `isRequired: false` for both is likely correct, but verify against real behavior, don't assume).

### 2. `SpokeController` — resolve active connectors through the Blueprint, don't just fire everything

- Add an optional `blueprint: Blueprint?` (default `nil`) and `configuration: BlueprintConfiguration` (default an empty one keyed to the blueprint's name, or `nil` — your call on the exact default-construction idiom, but it must mean "use every slot's shipped default, no per-tenant override yet") parameter to `SpokeController.init`.
- `gatherSignals()`: if a `blueprint` is present, resolve the set of `activeConnectorID(forSlot:in:)` across all its `connectorSlots`, and only call `.fetch()` on connectors whose `connectorID` is in that resolved set (skip/log the rest — don't silently fetch connectors that aren't actually slotted, and don't silently drop ones that are). If `blueprint` is `nil` (the `AiOSMyFamily` case, and both empty-array preview construction sites in `ContentView.swift`), preserve today's exact behavior — fire every injected connector unconditionally. This must be a strict superset of today's behavior for anything not touched, and a real, provable behavior change only for the one thing you're wiring.
- Wire `AiOSBusinessApp.swift`'s real `SpokeController(...)` construction to pass the real `JobSeekerBlueprint` instance (find/confirm how one gets constructed elsewhere — e.g. check `ContentView.swift`/wherever Job Seeker's flows already build one — reuse that construction, don't invent a second one) and a default `BlueprintConfiguration`.
- Do NOT change `AiOSMyFamilyApp.swift`'s construction — no matching Blueprint exists there, correctly out of scope.

### 3. Prove it's real, not cosmetic

The acceptance bar here is the same one `TidyIndexObjectBridge` cleared: this needs to be provably wired, not just compiling. A test (or, if `SpokeController`'s `@MainActor`/`@Observable` nature makes it awkward to unit-test directly, a focused new test on the resolution logic itself, extracted if needed into a small testable function/type in AiOSCore) must demonstrate: with a real `JobSeekerBlueprint` and a `BlueprintConfiguration` that reassigns one slot to a different connector (or unwires one), `gatherSignals()`'s actual behavior changes accordingly — i.e., the configuration genuinely controls which connector fires, not just which one is nominally "active."

---

## Tests

- `AiOSCore/Tests/AiOSCoreTests/ConnectorSlotTests.swift` or a new file — if you extract resolution logic into AiOSCore (recommended per the "prove it's real" section, since `SpokeController` itself isn't easily unit-testable being `@MainActor`/UI-app-target code), add real tests there: a `Blueprint`+`BlueprintConfiguration` pair resolves to the right connector ID for a slot; an override in `slotWiring` beats the shipped default; an unwired slot (no override, no shipped default) resolves to `nil`.
- Confirm `ConnectorSlotTests.swift`'s existing tests still pass unchanged.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSBusiness" && xcodebuild -project AiOSBusiness.xcodeproj -scheme AiOSBusiness -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on all five combinations. A prior brief broke the iOS Simulator build by only testing macOS — do not repeat that. `AiOSMyFamily` is touched only if the compiler forces a signature change (e.g. a new required init param) — if so, pass `blueprint: nil` explicitly there and confirm behavior is unchanged.

---

## Acceptance criteria

1. `JobSeekerBlueprint` has real, non-empty `connectorSlots` matching its app's actual injected connectors.
2. `SpokeController.gatherSignals()` genuinely resolves which connectors fire through `BlueprintConfiguration.activeConnectorID(forSlot:in:)` when a Blueprint is present — proven by a test where changing the configuration changes which connector fires.
3. `AiOSMyFamily`'s behavior is unchanged (no Blueprint = fire everything, exactly as today).
4. `AiOSBusiness`'s behavior is unchanged in practice for this slice (the default configuration should resolve to exactly the same two connectors already firing today) — this is a wiring/plumbing change, not a behavior change, on day one. The point is that the mechanism is now real and provably override-able, not that anything currently visible changes yet.
5. All five build/test combinations green.

---

## Commit

```
feat(library): wire the real ConnectorSlot/BlueprintConfiguration checkout mechanism into Job Seeker's spoke

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (`JobSeekerBlueprint` slots, resolution logic + tests), AiOSBusiness (`SpokeController` wiring, app construction), AiOSMyFamily (only if compiler-forced, behavior-preserving).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/JobSeekerBlueprint.swift` | AiOSCore | MODIFY — populate `connectorSlots` |
| `AiOSCore/Sources/AiOSCore/ConnectorSlot.swift` (or a new small file) | AiOSCore | MODIFY/CREATE — resolution helper, if extracted for testability |
| `AiOSCore/Tests/AiOSCoreTests/ConnectorSlotTests.swift` | AiOSCore | MODIFY — new resolution tests |
| `AiOSBusiness/AiOSBusiness/SpokeController.swift` | AiOSBusiness | MODIFY — `gatherSignals()` slot-aware resolution |
| `AiOSBusiness/AiOSBusiness/AiOSBusinessApp.swift` | AiOSBusiness | MODIFY — pass real Blueprint + default configuration |
| `AiOSMyFamily/AiOSMyFamily/SpokeController.swift` / `AiOSMyFamilyApp.swift` | AiOSMyFamily | MODIFY only if compiler-forced, behavior-preserving |
