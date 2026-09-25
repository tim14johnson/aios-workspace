# CLI Brief — App Intents: AiOS as the left hand to Siri's right

**Filed:** 2026-09-25
**Decision (Tim, 09-25):** App Intents is **next**. *"It makes us the left hand to Apple/SiriAI's right hand."*
**Centerline:** `docs/centerline/01-spine.md` Part 2 §10 (working in tandem with Apple).
**Supersedes:** `docs/cli-shortcuts-siri-integration.md` (09-11), for the App Intents half. That brief
predates the index spine: its first intent called `TaxDocumentDiscoverer`, a vertical-specific
discoverer the spine retires. Its **Shortcut-as-connector spike** (question 2) is a separate idea. It
moves to the connector catalog (`docs/centerline/03`), and nothing here depends on it.

---

## The idea in one paragraph

Siri is the front door. AiOS is the thing behind it that knows your NAS, your businesses, your
third-party systems and what's waiting for your decision, with a citation for every claim. We expose AiOS's **entities** (organizations, projects, and later people and files) as App Entities, and its **grounded answers and governed actions** as App Intents. When someone asks Siri "what's waiting on me for Valley Perinatal?", the answer comes from the AiOS index. AiOS never builds its own voice interface (dropped 09-25; Siri is the voice).

## Today

A repo-wide grep finds **zero** `AppIntent` / `AppEntity` / `AppShortcutsProvider` in all four
targets and AiOSCore.

## Prerequisite — do not start before this

**Merge the open branches.** Slice 1 depends on `OrganizationDirectory` (Slice 5, on
`feature/slice5-org-home`), and Hub `main` doesn't build from clean without `feature/model-library`.
Merge order: `tools/briefs/2026-09-24-model-library-checkout.md`. That's Tim's call. If the branches aren't merged, stop and report. Don't build on top of an unmerged stack.

## Design rules

1. **Intents read the index. Nothing else.** No intent calls a vertical discoverer or a vertical
   store. If the index can't answer a question, the intent doesn't exist yet. The gap goes back to the spine, not to a workaround.
2. **Every spoken answer is grounded.** The dialog states counts and names that come from real edges/items. When there's nothing to cite, the answer says so and gives the reason ("nothing pending", "the Hub isn't reachable"). It never says "I think".
3. **Read-only first.** Actions come in a later slice, behind the central action-class check.
4. **Tenant is enforced by the paired connection, never by the intent.** A family-paired iPhone must not surface business organizations, whatever Siri was asked.
5. **Location:** a new `AiOSIntents` library target inside the AiOSCore package, alongside `AiOSUI`, so `AiOSCore` itself doesn't import AppIntents. Verify via DocumentationSearch that App Intents
   declared in a Swift package are discovered for the host app (the `AppIntentsPackage` mechanism).
   If that isn't reliable on the current toolchain, put the intents in the app target and keep only
   the query logic in Core. Report which way it went.

---

## Slice 1 — Hub (Mac): entities + one read-only intent (build first)

The Hub runs on the Mac Studio, where the index lives. That means no transport and no tenant
crossing, so it's the smallest real slice.

- **`OrganizationEntity: AppEntity`**: backed by `OrganizationDirectory` (name, tenant, aliases).
  Its `EntityQuery` resolves by id and by name/alias, so Siri can match "Valley Perinatal".
- **`ProjectEntity: AppEntity`**: backed by the shared `ObjectStore` project entities.
- **`PendingReviewIntent`**: "What's waiting for review for *{organization}*?"
  - Query: pending `EdgeStore` edges to that organization (`edges(to:…)`, review state `.pending`).
  - Dialog: *"Valley Perinatal has 14 files waiting for review; the newest is `2025-11 invoice.pdf`."*
    Counts plus one or two named examples. Those names are the citations.
  - Opens the Hub's Tidy review filtered to that organization when the user taps through
    (`openAppWhenRun` or an `OpenIntent`; pick the API DocumentationSearch recommends).
- **`AppShortcutsProvider`** with 2–3 natural phrases per intent, so it works without the user
  building a Shortcut.

**Tests:** unit-test the query/summary logic in Core against an in-memory `EdgeStore` +
`OrganizationDirectory`: counts, tenant filtering, the empty case, and the alias match. The intent
wrapper itself is verified manually in the Shortcuts app and by Siri on the Mac.

**Tim's check:** on the Studio, ask Siri "what's waiting for review for Valley Perinatal in AiOS".

## Slice 2 — iPhone/iPad: the same intent over the paired channel

- Add **one** read-only `HubRequest` case for index queries (e.g. `queryIndex(IndexQueryRequest)`:
  a target entity, an edge type, a review state and a minimum confidence). **This is the same "one
  Hub request" Studio pipeline Slice 4 needs** for lenses. Build it once, with that shape, so Slice 4
  reuses it rather than adding a second one.
- `HubRequestRouter` uses its **bound tenant** and filters edges by tenant (spine decision #4: the
  edge carries the tenant). A family connection asking about a business organization gets "not
  found", not an error that leaks the organization exists.
- The spoke apps' intents call the Hub through the existing `PairedHubClient`. When the Hub is
  unreachable, the dialog says so plainly.

## Slice 3 — Put AiOS entities into Apple's semantic index

Verify via DocumentationSearch: `IndexedEntity` / Core Spotlight donation of App Entities, so Apple
Intelligence's personal context can find AiOS organizations and projects without the user naming the
app. Gate it on OS availability (the package floor is macOS 14 / iOS 17). Scope is **entity names and
ids only**. No file contents, and nothing from the People lens (hard-line data rule).

## Slice 4 — Governed actions

The first action intents are "confirm" or "reject" on a pending association, then "run tonight's
pass now". Each declares its `ActionClass`. **The central Hub action-class check (spine gap #2) is
built here, as its first consumer.** It is not built as intent-specific logic.

---

## Non-goals

- No own voice loop, no SpeechAnalyzer/TTS work.
- No legacy SiriKit.
- No intents over vertical stores (`TaxDocumentDiscoverer`, `CrossDomainFileTagStore`, `CaptureStore`).
- No write actions before Slice 4.

## Build verification (Slice 1)

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. Both spokes still build.
