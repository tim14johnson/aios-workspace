# CLI Brief — Re-pair AiOSMyFamily as `.business` so Valley Perinatal's sync works through the real tenant boundary

**Filed:** 2026-09-23
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md` §5 (the tenant-isolation fix that made this necessary), `tools/briefs/2026-09-23-tenant-isolation-fix.md`.
**Priority context:** Tim's explicit next step after the tenant-isolation security fix landed (commits AiOSCore `c3623d0`, AiOSMyFamily `5c0838d`). He is stepping away and asked this proceed without further check-ins — build it fully, he'll test the live pairing handshake himself later (a human has to approve pairing on the Hub side; that part cannot be automated).

**Goal:** `HubRequestRouter` now correctly authorizes every request by the tenant of the actual paired connection, never a client-claimed field (tonight's fix). Valley Perinatal's `FinanceProject` genuinely lives in the `.business` workspace, but `AiOSMyFamily` — the only app that runs `ValleyPerinatalController` — has never paired as anything but `.family`. Its `sync()` now correctly fails with "Valley Perinatal project not found on the Hub." This brief gives `AiOSMyFamily` a real, second `.business` pairing, and points `ValleyPerinatalController` at it — so VPS reaches its data through the boundary being properly enforced, not around it.

**Grounded in real code, read in full tonight:**
- `SpokeController` (`AiOSMyFamily/AiOSMyFamily/SpokeController.swift`) is **already fully generic over `Tenant`** — `init(tenant: Tenant, connectors: [any SpokeConnector])`, its `pair()`/`unpair()`/`pairing`/`verificationCode`/`deviceFingerprint` all key off `self.tenant`, and `SpokeBindingStore`/`DeviceIdentity.loadOrCreate(account: "com.aios.spoke.\(tenant.rawValue).identity")` already namespace by tenant string. **No AiOSCore change is needed for this brief** — every primitive it needs (`SpokePairingClient`, `PairedHubClient`, `DeviceIdentity`, `SpokeBindingStore`, `Tenant`) already supports a second tenant identity on the same device. Confirm this by reading, but the brief's own research tonight found zero blockers.
- `ValleyPerinatalController.hubClient()` (`AiOSMyFamily/AiOSMyFamily/ValleyPerinatalController.swift:166-171`) currently hardcodes `.family` for both `DeviceIdentity.loadOrCreate(account: "com.aios.spoke.\(Tenant.family.rawValue).identity")` and `SpokeBindingStore().load(tenant: .family)`. Its own doc comment (added by tonight's tenant-isolation-fix slice) already describes exactly this fix as the intended follow-on.
- `ContentView.swift` (`AiOSMyFamily/AiOSMyFamily/ContentView.swift`) constructs exactly one `SpokeController(tenant: .family, connectors: [...])` (in `AiOSMyFamilyApp.swift`) and has a real, reusable pairing UI component, `HubConnectionView` (line 322-383, takes `let spoke: SpokeController` and renders the full pairing state machine — paired/pending/denied/error/unpaired, verification code display, manual Tailscale address field, unpair button). **This view is already generic over which `SpokeController` it's given** — reuse it directly for the new `.business` pairing UI, don't build a second one.

**Explicit non-goals:**
- Do NOT build any duplication/grant mechanism for cross-tenant data. Not this brief — a real second pairing is the whole point.
- Do NOT touch `HubRequestRouter`, `PairedHubService`, `Tenant`, or anything in AiOSCore. Confirmed nothing there needs to change. If you find otherwise while reading the real code, stop and report why rather than proceeding on an assumption that turns out wrong.
- Do NOT try to complete or simulate the actual pairing handshake — it requires a human (Tim) to approve the new device on the Hub's own UI. Your job is to make the infrastructure and UI real and correct; he will complete the live pairing himself "later tonight/tomorrow" per his own words.
- Do NOT give the new `.business`-tenant `SpokeController` any connectors (`connectors: []`) — Valley Perinatal doesn't need spoke-side sensors, only the pairing/hub-transport plumbing. Don't invent connector needs that don't exist.
- Do NOT touch `AiOSBusiness` — this is exclusively an `AiOSMyFamily`-side change (AiOSBusiness already pairs as `.business` natively; nothing there needs updating).

---

## What to build

### 1. A second, `.business`-tenant `SpokeController` instance in AiOSMyFamily

In `AiOSMyFamilyApp.swift`, add a second `@State private var businessSpoke = SpokeController(tenant: .business, connectors: [])` alongside the existing `.family` one, and inject it into the environment too (check how `ContentView.swift` currently receives its single `SpokeController` via `@Environment(SpokeController.self)` — since SwiftUI's environment is keyed by TYPE, not by an instance property, injecting a second `SpokeController` this way will collide with the first. You'll need a way to distinguish them — e.g. give `ValleyPerinatalView` (or wherever the new pairing UI lives) this second controller via a direct `let`/parameter instead of `@Environment`, rather than fighting SwiftUI's single-type environment resolution. Check how the existing single-environment injection is actually consumed at each `@Environment(SpokeController.self)` call site before deciding the cleanest non-colliding approach — your call, but don't silently let the second instance shadow or replace the first in the environment.)

### 2. Pairing UI for the new `.business` connection

Somewhere sensible in the Valley Perinatal feature's own view (find `ValleyPerinatalView.swift` or wherever `ValleyPerinatalController` is actually presented — grep for it), add a section reusing the existing `HubConnectionView(spoke: businessSpoke)` component — it already renders the full pairing state machine generically. This gives Tim a real "Pair with Business hub" affordance inside the Valley Perinatal screen, distinct from the app's existing main `.family` pairing UI.

### 3. Point `ValleyPerinatalController.hubClient()` at the real `.business` binding

Simplest correct fix: change the two hardcoded `.family` references in `hubClient()` to `.business`. Update the doc comments on `hubClient()` and the `NOTE` in `sync()` (both were written tonight anticipating this exact fix) to describe the new, correct state instead of the old workaround. If `ValleyPerinatalController` is constructed independently of the new `businessSpoke` instance (matching its existing "standalone, no injected SpokeController dependency" pattern), it's fine to keep that independence — `hubClient()` re-deriving its own `.business` identity/binding directly (rather than reaching into `businessSpoke`) is consistent with how it already works for `.family` today, and avoids a new dependency wire-up. Your call, but simpler is better here — don't force an injected-dependency refactor this brief doesn't need.

### 4. Real failure messaging until pairing actually happens

Since the live pairing handshake can't be completed by you, confirm `sync()`'s existing failure path ("Pair with the Hub first — Valley Perinatal resolves its project over the paired Hub connection.") still fires correctly when `.business` isn't yet paired (it should, automatically, once `hubClient()` returns `nil` for an unpaired `.business` tenant) — this is the expected, correct state until Tim pairs it live.

---

## Tests

`SpokeController`/pairing itself already has real test coverage (confirm by grep) — this brief's job isn't to re-test pairing mechanics, just to prove the wiring is correct: `ValleyPerinatalController.hubClient()` constructs against `.business`, not `.family` (a test can verify this without a live pairing, e.g. by checking which `DeviceIdentity` account string / `SpokeBindingStore` tenant it queries — check what's actually testable given `hubClient()`'s current shape, and add a focused test if a clean seam exists; if it doesn't cleanly unit-test without deeper refactoring, say so honestly rather than forcing a low-value test).

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug test -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on both platforms. This touches AiOSMyFamily only — confirm via grep that nothing in AiOSCore/AiOSHub/AiOSBusiness needed changes before concluding.

---

## Acceptance criteria

1. AiOSMyFamily can initiate and display a real `.business`-tenant pairing (Tim can complete the human-approval half himself later).
2. `ValleyPerinatalController.hubClient()` resolves against the `.business` identity/binding, not `.family`.
3. The existing `.family` pairing UI/flow (main app) is completely unaffected — confirmed by diff.
4. Both build platforms green; existing tests unaffected in intent.
5. Doc comments written during tonight's tenant-isolation fix (which anticipated this exact follow-on) are updated to reflect the real fix, not left describing a stale workaround.

---

## Commit

```
feat(index): re-pair AiOSMyFamily as .business so Valley Perinatal reaches its real workspace through the enforced tenant boundary

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSMyFamily only.

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSMyFamily/AiOSMyFamily/AiOSMyFamilyApp.swift` | AiOSMyFamily | MODIFY — second `.business` `SpokeController` |
| `AiOSMyFamily/AiOSMyFamily/ContentView.swift` | AiOSMyFamily | MODIFY only if environment-injection collision requires it |
| `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalController.swift` | AiOSMyFamily | MODIFY — `hubClient()` uses `.business` |
| `ValleyPerinatalView.swift` (find real name/path via grep) | AiOSMyFamily | MODIFY — add business pairing UI section |
