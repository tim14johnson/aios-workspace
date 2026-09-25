# CLI Brief — The Studio pipeline: make Tidy Files' night pass able to take in *all* the data, and start learning from it

**Filed:** 2026-09-23
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md` (Phases 0–3), `docs/architecture/2026-09-22-spotlight-schema-mapping.md`, `context/memory/nas-spotlight-smb.md`.
**Supersedes:** `tools/briefs/2026-09-23-compute-queue-hardening.md` (shelved: spokes have no compelling compute job right now).

**Tim's core tenet (2026-09-23):** *"I need this thing to start getting smarter about all of the data, in all of the places."*

**Decisions already made (2026-09-23), don't re-litigate:**
- **One place for everything:** the NAS, under the AiOS folder tree. Deduped, properly named, foldered by **Organization / Sub-org / Category / Project** (no Business/MyFamily layer; see decision C below). A sync folder or cloud for active data comes later and is not in scope.
- **The Mac Studio (the Hub) does all the heavy work:** crawl, hash, OCR, classify, apply. Spokes do none of it.
- **Other Macs are reached by macOS File Sharing**, mounted on the Studio and listed in `OrganizerController.nasVolumePaths`, exactly like the NAS. That list already crawls any path that's currently mounted (`OrganizerController.swift:911-921`). The old Intel Macs are handled the same way.
- **Nothing is distributed.** A throughput measurement (Slice 1) decides whether that ever changes.

**Status (2026-09-24):** Slices 1–2 done. Slice 3 partly done (3a, 3b first part, plus the 09-24 map fixes below). Slices 4 and 6 not started. **Slice 5 is being built** (overnight 2026-09-24, branch `feature/slice5-org-home`). **Hold bulk Apply until Slice 5 lands:** every file moved before then would have to move again.

---

## Why this is a series of slices, not one change

The night pass already does the whole pipeline: crawl → OCR (images) → tag → classify → dedupe → propose → auto-apply → reconcile. A read of the real code (2026-09-23) found that it works at the scale of **one folder in one session**. It **breaks at the scale of "everything"**, and it **doesn't learn**. Four findings, each verified in code:

| # | Finding | Where | Why it matters |
|---|---|---|---|
| F1 | **`CrawlLedger` rewrites its whole JSON file on every single file recorded.** | `AiOSCore/Sources/AiOSCore/CrawlLedger.swift:46-66`: `record()` → `persist()` → encode all entries → atomic write | Quadratic. At ~100 B per entry, a 500k-file NAS gives a ~50 MB file rewritten once per file. The whole-NAS backlog can't complete. |
| F2 | **Proposals live only in memory, but the ledger marks their files as done.** | `rows` is `private(set) var rows: [Row] = []` (`OrganizerController.swift:133`), not persisted. `scanStream` calls `ledger.record` at `:1320` as soon as a row is proposed | Relaunch the Hub, or run a manual scan (`process(url:)` sets `rows = []`, `:814`), and every unapplied proposal disappears. Their files are never proposed again until they change. A multi-night backlog silently loses work. |
| F3 | **Documents are classified almost blind.** | `scanStream` (`:1280-1287`) only builds `contentText` from image OCR. PDF and document text is read by `ContentTagger` (`ContentTagger.swift:33`, PDFKit) for NER tags, but **after** `TidyOrganizer.proposal(...)` has already chosen the destination, and it's never passed in as evidence. Scanned PDFs (no text layer) get no text at all. Spotlight text doesn't exist on the NAS (settled). | The Business / MyFamily routing and naming for the most important files (PDFs, scans, docs) rest on filename and folder alone. |
| F4 | **Nothing learns from Tim's decisions.** | `FeedbackLog` (`AiOSCore/Sources/AiOSCore/FeedbackLog.swift`) is appended on every approve, move, skip and undo. **`events()` has zero callers anywhere.** Per-row schema corrections (`schemaEdits`) are cleared on each fresh scan. | This is the direct gap behind the tenet. Every correction Tim makes is recorded and then ignored. The system can't get smarter yet. |

Secondary, fix alongside if cheap:
- **S1:** `rebuildGroups()` re-groups and re-sorts all `rows` on the main actor after every 10-file batch (`:1038`, `:594`). That's close to quadratic main-thread work as `rows` grows. Rebuild once per pass, or throttle.
- **S2:** Duplicate detection re-hashes every same-size candidate on every night pass, with no hash cache (`Duplicates.swift:123-132` via `OrganizerController.swift:1196`). Over SMB, that's re-reading the same bytes nightly.
- **S3:** Listed volumes that aren't mounted are skipped silently (`:919`). With remote Macs in the list, "the MBP was asleep" must show up in the night summary.

Slices below are in dependency order. **Slice 1 goes to the CLI now.** Slices 2–6 are scoped enough to sequence, and each gets its own full brief when its turn comes. Slices 3–6 build the spine described in "The spine this pipeline feeds" below.

---

## Slice 1 — Make it survive "everything" (build now)

**✅ DONE (2026-09-23).** AiOSCore `2afe88b`, AiOSHub `6ab0888`. AiOSCore 917/917 green; AiOSHub 31/31 green; AiOSBusiness and AiOSMyFamily macOS builds green.
- 1a: append-only JSONL ledger with compaction and migration. **Also fixed:** the old `.iso8601` dates dropped sub-second precision, so after every relaunch every file with a sub-second modDate looked changed and the crawl effectively started over.
- 1b: option (i), a persisted queue (`TidyPendingQueueStore`). (ii) was rejected because rows are approved by default: a rejected file would have come back pre-approved.
- 1c, 1d, and S1 (throttled regrouping): done. **S2 (hash cache) deferred:** it needs a schema change to the shared cross-vertical `TagCache`.
- **Found and fixed on the way:** the AiOSHub test host is the real app. Tests read and wrote Tim's real Tidy Files settings, crawled his real scan folders via the launch-time Spotlight → night pass, and overwrote his remembered source folder. Tidy settings, ledger, queue and metrics are now isolated under XCTest (`TidyDefaults`), and Spotlight indexing is skipped there.
- **Not yet covered by a controller-level test** (the paths need real UserDefaults-backed folders): the unmounted-volume summary (covered at the `TidyNightMetrics` level) and `process(url:)` forgetting displaced rows (covered at the `CrawlLedger.forget(paths:)` level).

### 1a. `CrawlLedger`: incremental persistence
Replace the rewrite-everything write with an append-only log. Follow the JSONL pattern `FeedbackLog`/`EntityDecisionLedger` already use; don't invent a third storage style. Suggested shape:
- One line per `record`/`setCursor`/`forget`. Last write for a key wins on load.
- Compact (rewrite once) on load, or when the log exceeds N× its live entry count.

The public API (`hasChanged`, `record`, `cursor`, `setCursor`, `forget`, `count`) stays **unchanged**. Existing ledger files must load (migrate once from the current JSON format). No crawl behavior change.

### 1b. Don't lose proposals
Pick the smaller correct fix and justify it in the commit:
- **(i)** Persist the pending proposal queue (the `Row`s that aren't applied, rejected or moved), plus `schemaEdits`, `chosenDestination` and approval state, and restore it on launch. `Row` isn't `Codable` today (`:12`).
- **(ii)** Record a file in the ledger only once its proposal is resolved (applied, rejected, or auto-applied), not when it's proposed. Unresolved files then naturally come back on the next pass. Cost: re-tagging, which `TagCache` (SwiftData, already persisted) mostly absorbs.

(ii) is likely smaller. (i) gives a better morning, because yesterday's queue is still there when you open the app. **Either is acceptable. Losing work silently is not.** Also: a manual `process(url:)` scan must not wipe the night queue's un-reviewed rows without saying so.

### 1c. Throughput measurement: the number that decides everything later
Add per-stage timing to the night pass: files enumerated, OCR count and time, tag time, classify time, hash bytes and time, per root. Put a one-line **files/hour and bytes/hour** into `nightSummary`, and append a structured per-night record to a small JSONL file in the Hub's application support folder, so trends are readable later. **This is the Studio throughput test.** Tim runs it on one real NAS subfolder and estimates the whole backlog from it. No UI beyond the summary line.

### 1d. Say what was skipped
In `runNightPass()`, name any `nasVolumePaths` entry that wasn't mounted in `nightSummary` (e.g. "Skipped (not mounted): /Volumes/Tims-MBP-Home"). Leave the skip behavior itself unchanged.

### 1e. (If cheap) S1 + S2
- **S1:** move `rebuildGroups()` out of the per-batch loop in `crawlOneFolder` to once per pass, with a throttled progress update if the UI needs liveness.
- **S2:** cache content hashes keyed by `(path, modDate, size)`. `TagCache` already keys on exactly this; extending it is preferred over a new store. Then `DuplicateFinder` only hashes files whose key changed.

If either grows beyond small, stop and report instead; they can be Slice 1.5.

### Slice 1 non-goals
- No change to classification logic, schema, destinations, auto-apply thresholds, or what gets moved.
- No spoke/`ComputeJobQueue` changes (shelved).
- No routing or folder-tree change (that's Slice 5).
- No new UI screens.

### Slice 1 tests
- `CrawlLedger`:
  - Same observable behavior as today: an existing-format file loads, and `record`/`hasChanged`/`forget`/cursors round-trip across instances.
  - Append plus compaction produces the same state.
  - A performance guard: recording 50k entries finishes in bounded time (it's quadratic today). Assert the write count or size, not wall-clock, so it isn't flaky.
- 1b:
  - For (ii): a proposed-but-unresolved file is re-proposed on the next pass, and an applied file is not.
  - For (i): the queue round-trips through persistence, including schema edits and approvals.
- 1c: the stage counters add up, and the summary line appears. Unit-test the aggregation, not a real crawl.
- 1d: an unmounted listed path appears in the summary.
- All existing AiOSCore and AiOSHub tests stay green, with no weakened assertions.

### Slice 1 build verification
```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. `CrawlLedger` is in AiOSCore, so grep for other users of it (spokes, `SpotlightDiscoverer`) and confirm they build unchanged.

### Slice 1 commit
```
feat(tidy): Studio pipeline slice 1 — incremental CrawlLedger, no lost proposals, night-pass throughput metrics, report unmounted volumes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

### Tim's part after Slice 1
1. Mount one real NAS subfolder of meaningful size (a few thousand files, mixed PDFs, scans and photos) and list it.
2. Run Now, and read the files/hour line.
3. That number sizes the backlog in nights, and decides whether OCR ever needs distributing.

---

## Slice 2 — Read the documents

**✅ DONE (2026-09-23).** AiOSCore `90dd38d` + `2917ade`, AiOSHub `7ddb960` + `7a696ed`. AiOSCore 920/920, AiOSHub 39/39, both spokes build.
- New `DocumentText` (AiOSHub): text files (256 KB cap), the PDF text layer (first 20 pages), Vision OCR of the first 3 pages when there's no text layer, RTF, and `.docx`/`.odt` via `unzip` (never the WebKit importers). Capped at 20k characters. The old "read any file whole as UTF-8" fallback is gone; on the NAS it pulled multi-GB videos into memory.
- The crawl caches document text in `TagCache`, derives NER tags from it, and hands it to finance promotion. Tested: a scanned `scan001.pdf` 1099 gets a finance/tax tag with tax year 2024. **Naming unchanged:** document text never names a file.
- One-time backfill (`TidyFiles.documentTextBackfill.v1`): document-type ledger entries are forgotten once, so already-crawled files get read. The summary reports "Re-reading N earlier documents once for their text."
- The crawl loop now ends a root when a pass processes fewer files than its cap, not when it yields fewer new rows.
- **Verified along the way:** `SchemaClassifier` never reads `SchemaEvidence.ocrText`. Where files are routed is still folder heuristics only; text-based placement belongs to Slices 4–5.
- **Not done:** `.doc` (legacy binary Word), `.pages`, spreadsheets. A document with genuinely no extractable text is re-attempted whenever the ledger lets it through (cheap after the backfill; no "no text" marker yet).


Every lens in Slice 4 depends on this: a finance, jobs or FFA lens can't see a scanned 1099 or offer letter without its text.

Close F3. Before classification, build `contentText` for documents, not just images:
- PDF text layer (PDFKit; `ContentTagger` already does this. Hoist it so it runs once and both classification and tagging use it).
- **Vision OCR for scanned PDFs**, where the text layer is empty. `ContentDescriber` / `PDFCatalogIngester` already use `VNRecognizeTextRequest`, so reuse that.
- `.doc`/`.docx`/`.rtf`/`.txt` via the AppKit importers `ContentTagger` already uses.

Cache the text through `TagCache` (already keyed by path, modDate and size; it already stores `contentText`). A file is read once, ever, unless it changes. Page-cap large PDFs (first N pages) and record that the text is partial. Slice 1c's metrics show the cost.

---

## The spine this pipeline feeds (decided with Tim, 2026-09-23)

**Full architecture reference:** `docs/architecture/2026-09-23-index-spine.md` (everything is a lens; items, entities, associations; lens kinds; guardrails; sequence). This section is the pipeline's slice of it.

**The product is the index:** a searchable map of everything stored (for Tim, the NAS; for other users, wherever their data lives), plus an association graph of every vertical each file touches. Finance, Jobs and FFA aren't separate searches. Each is a *lens* over the same index. The analytics/insight engine assembles a blueprint from lens queries (datasets), a model, and connectors, and turns the result into suggestions, or into autonomous moves once confidence is earned.

```
File store (millions)          ObjectStore (hundreds–thousands)
  file: hash, locations,         entity: person, org, project,
        text/tags pointer                job application, tax year,
                                         FFA chapter…
          \                          /
           └──── Associations ──────┘
     file ↔ entity   ("this PDF is Valley Perinatal's 2025 invoice")
     file ↔ vertical ("relevant to Finance, 0.92")
     entity ↔ entity ("Tim works for Valley Perinatal")
     each edge: confidence · provenance · review state · tenant
```

**Decisions:**
- **A. Files get their own store, built for NAS scale** (SQLite/SwiftData, like `TagCache`). `ObjectStore` keeps entities; it's load-all/save-all JSON sized for "tens-to-hundreds of entities" by its own doc, so it can't hold a NAS. The two are peers, and associations link them.
- **B. Files have no tenant. Associations carry it.** One file can be Business context and MyFamily context at once, without copies. (This reverses the 2026-09-22 "duplicate files that live in both" direction.)
- **C. The NAS tree has no Business/MyFamily layer.** It starts at Organization: `Org / Sub-org / Category / Project / …`, per the defined schema. Business and family still separate visually because the orgs themselves differ (Valley Perinatal, Mazzaroth Pictures, Johnson Family/Household, FFA). A file's single physical home comes from its strongest organization association. Everything else about it is associations. The folder tree is a browsable *view*, not the source of truth. If NAS access is ever shared, DSM permissions go per organization folder. *(Code impact: `TidyTaxonomy.defaultPolicy` currently puts MyBusiness / MyFamily / MyHousehold at the top. Change it in Slice 5, not before.)*
- **This is Phase 0 (index unification), finished for files.** From here on, no new vertical-specific file discoverers (e.g. `TaxDocumentDiscoverer`, a Finance-only `CrossDomainFileTagStore`). Verticals query the index.

**Gaps against the spine, verified in code 2026-09-23:**
- Six differently-shaped stores, none of which is the map: `TidyIndex` (only files Tidy Files *moved*), `TagCache`, `CrossDomainFileTagStore` (Finance-only, whole-file rewrite per save), `ObjectStore` + `Association`, `SpotlightIndexStore`, `CrawlLedger`.
- Files reach the graph only on apply (`bridgeToObjectGraph`, called only from the move paths).
- `Association` has no confidence or review state. That's what suggest-vs-act needs.
- Search-vs-crawl for Finance was never joined: `FinanceFileDiscoverer.discover` has zero callers, Finance still discovers by filename (`FinanceFlow.swift:378`), and the Hub's finance tags never reach the MyFamily app (no Hub request carries them). Spotlight search can't see the NAS at all, so "search" must mean querying AiOS's own index.
- WP3 "linked copies" (`linkedCopyRows`, `TidyIndex.recordCopy`) physically copies a multi-person file into each person's folder. Under decision B that's two associations on one file. **Don't build on it.** Retire it, or replace it with Finder aliases, once Slice 3 lands. Don't remove it before then.

---

## Slice 3 — The map: every file is an entry in the index

**✅ 3a DONE (2026-09-23).** AiOSCore `fd7b1db`, AiOSHub `d22c146`. AiOSCore 930/930, AiOSHub 40/40, both spokes build.
- `ItemStore` (SwiftData, `~/Library/Application Support/AiOS/item-index.store`): items with `kind`, stable ids across moves, content hash when known, no tenant. Scale check: 20k items in ~5.5 s, path lookups ~0.1 ms.
- `EdgeStore` (SwiftData, `edge-index.store`): associations with confidence, source + evidence, review state and tenant. Re-proposals never override a human decision.
- The crawl writes items with every batch. Items follow approved moves, auto-apply, undo, revert, and Finder changes. A one-time backfill seeds the map from `TagCache`. The night summary reports "Map: N items (M recorded tonight)".

**✅ 3b (first part) DONE (2026-09-23).** AiOSCore `c2f1693`, AiOSHub `de3a7a8`. AiOSCore 933/933, AiOSHub 41/41, both spokes build.
- **Tim decided: one shared set of entities.** `ObjectStore.sharedEntities()` (`AiOS/Entities/shared.json`). The visibility rule is in the spine doc §2.6.
- The crawl proposes **file → shared Project** links (`part_of`, pending, the classifier's confidence, the folder trail as evidence). The tenant comes from the taxonomy's top-level category: MyBusiness → business; MyFamily / MyHousehold → family. That level is a category today, not an organization, so **no Organization entities or links yet**; those come with the org-first tree (Slice 5).
- Duplicate detection's hashes are stored on the map. `edges(to:)` filters inside the query.

**✅ 09-24 fixes to the map and to Tidy (outside the plan, after the 09-23 NAS run).** AiOSCore `9cae243`, AiOSHub `452a4c3`, AiOSMyFamily `0395abe` (branch `fix/tidy-placement-and-brain-budget`). AiOSCore 973/973, AiOSHub 59/59. Report: `docs/architecture/overnight-run-2026-09-23.md` + `…-2026-09-24-followup.md` (local; `docs/` is untracked).
- **What went wrong on 09-23:** manual Apply moved ~2,800 files whose schema placement had no Organization. `SchemaPathBuilder` dropped the empty level, so they landed at `<NAS>/AiOS/<source folders>/…`. The classifier also rebuilt Tidy's own earlier layouts (`Screenshots/Screenshots/Images/2025-04/2020/`).
- **Every move now puts the file on the map:** `ItemStore.recordMove(factsIfNew:)`. Moves of never-crawled files used to be dropped.
- **Apply gate:** manual Apply leaves incomplete placements in place (same rule as auto-apply). The classifier ignores Tidy-derived layout folders.
- **Every Tidy action is journaled:** folder merges, identical-folder merges and duplicate trashing are now journaled and undoable. A similar-folder merge only trashes after a complete merge.
- **Remount-safe:** the saved destination survives a NAS remount (`Name` ↔ `Name-1`).
- **Hub beachball fixed:** `pendingMoveCount` walked every row about 5× per redraw; it's now cached per revision.
- **Brain prompt budget:** `RemoteAnalyticsEngine` batches signals (≤60k chars per request). Unbounded 136k–537k-token prompts had pushed the MLX server to 52 GB of 64 GB.
- **Dates from the file:** `FileDateResolver`: a date written in the text → filename → embedded metadata (EXIF / PDF / Office) → modified.
- **Data repair (not code):** move journal, TidyIndex and `item-index.store` re-pointed to where files really are (`-1` mount, the flattened `Tidy Files/` tree, unjournaled moves). The map holds 34,722 items and passes `integrity_check`. Backups: `~/Library/Application Support/AiOSHub/remediation/`.
- **Open:** 386 files from the 09-08 run have no trace on the NAS or in `#recycle` (269 from `1 From Synology/Tim Johnson/01 Tim Gigs`). 251 match several same-name copies in `Backups to be Sorted/Drobo` and weren't re-pointed.

**Slice 3 — still to do:**
- **Move existing vertical entities into the shared store,** after `HubRequestRouter` enforces the edge-based visibility rule (spine doc §2.6). Never before: per-tenant files are today's isolation.
- Migrate the TidyIndex bridge's File objects and `AssociationStore` edges into `ItemStore` / `EdgeStore`. Clean up the category-as-Organization entities the old bridge created ("MyBusiness", etc.).
- Freshness: unchanged files skipped by the ledger don't refresh `lastSeenAt`, and deleted files stay on the map. Needs a cheap "still there" sweep.
- Tim's approvals and schema corrections should confirm or redirect these links. That's Slice 6's learning loop; the edges already have the review state for it.
- Move tracking in the Hub is covered only by store-level tests.
- **Still open from 09-24:** Hub-level tests for the apply loops' map writes (store-level tests exist).

---

## Slice 4 — Lenses: one index, many verticals

A vertical declares a **relevance lens** in its blueprint: keywords, entity types, source folders/volumes, mail links. Running a lens over the index writes file↔vertical and file↔entity associations, with confidence and provenance, as `pending`. Then:
- **Finance** = `TidyCrossDomainPromoter`, generalized into the first lens. `CrossDomainFileTagStore`'s data migrates into associations.
- **Jobs** = second lens: application/listing/email-related files, linked to the Job Seeker entities that already exist.
- **FFA** = third lens. Three verticals prove it's generic, not Finance-shaped.
- **Fold in the tax checklist** (AiOSCore `aa708e9`, AiOSMyFamily `64d5dcf`, 09-24). It's a Finance-vertical list file plus one folder per expected document in the family tax tree, and it writes nothing to the map yet. In this slice each checklist item becomes an expectation the Finance lens checks, and each attached document becomes a file → tax-year association. Otherwise it's the vertical-specific store §2 warns against.
- **One Hub request:** "files associated with vertical X (tenant T) above confidence Y", going through `authorizedTenant(...)`. Every vertical, on any device, searches through that request instead of its own discoverer.

## Slice 5 — Physical home by organization (decision C)

A file's NAS home is its strongest organization association → `Org / Sub-org / Category / Project / …`. Replace the MyBusiness/MyFamily/MyHousehold top level in `TidyTaxonomy.defaultPolicy`. "Unsure" always goes to review, never to auto-apply.

**🚧 In progress (overnight 2026-09-24, branch `feature/slice5-org-home` in AiOSCore + AiOSHub, built in separate worktrees because another session is working in AiOSCore).** Nothing on the NAS is moved while it's being built.

## Slice 6 — Learn from Tim, per lens (the autonomy dial)

Close F4. `FeedbackLog.events()` and schema corrections feed back into association confidence: approvals raise it, corrections and rejections lower it or redirect it. Learned rules stay visible and revocable. Track **accept rate per lens** in the Slice 1 metrics log, nightly. That per-lens number is the autonomy dial: below a threshold a lens only suggests; above it, it may act, with every action journaled and revertible as today. Persist `schemaEdits` as corrections instead of clearing them on each fresh scan.

## After Slice 6

- **The insight engine plugs in:** a blueprint picks its datasets (lens queries), model and connectors, and produces suggestions or confident actions.
- **The morning digest:** `nightSummary` plus per-lens accept-rate trends go into the dashboard's Priority glance (`ContentView.swift:483` stub).
- **Revisit distribution** only if Slice 1's throughput number says the Studio can't clear the backlog in an acceptable number of nights.

---

## Key paths (Slice 1)

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/CrawlLedger.swift` | AiOSCore | MODIFY — append-only persistence + one-time migration |
| `AiOSHub/AiOSHub/OrganizerController.swift` | AiOSHub | MODIFY — 1b (proposal durability), 1c (stage metrics), 1d (unmounted report), 1e (S1/S2 if cheap) |
| `AiOSCore/Sources/AiOSCore/TagCache.swift` | AiOSCore | MODIFY (only if doing S2) — hash cache |
| Tests for the above (find existing `CrawlLedger`/`OrganizerController` tests via grep) | both | MODIFY/ADD |
