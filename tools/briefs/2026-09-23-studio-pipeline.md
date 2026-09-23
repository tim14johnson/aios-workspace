# CLI Brief — The Studio pipeline: make Tidy Files' night pass able to take in *all* the data, and start learning from it

**Filed:** 2026-09-23
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md` (Phases 0–3), `docs/architecture/2026-09-22-spotlight-schema-mapping.md`, `context/memory/nas-spotlight-smb.md`.
**Supersedes:** `tools/briefs/2026-09-23-compute-queue-hardening.md` (shelved: spokes have no compelling compute job right now).

**Tim's core tenet (2026-09-23):** *"I need this thing to start getting smarter about all of the data, in all of the places."*

**Decisions already made (2026-09-23), don't re-litigate:**
- **One place for everything:** the NAS, under the AiOS folder tree. Deduped, properly named, foldered by **Business / MyFamily**. A sync folder or cloud for active data comes later and is not in scope.
- **The Mac Studio (the Hub) does all the heavy work:** crawl, hash, OCR, classify, apply. Spokes do none of it.
- **Other Macs are reached by macOS File Sharing**, mounted on the Studio and listed in `OrganizerController.nasVolumePaths`, exactly like the NAS. That list already crawls any path that's currently mounted (`OrganizerController.swift:911-921`). The old Intel Macs are handled the same way.
- **Nothing is distributed.** A throughput measurement (Slice 1) decides whether that ever changes.

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

Slices below are in dependency order. **Slice 1 goes to the CLI now.** Slices 2–4 are scoped enough to sequence, and each gets its own full brief when its turn comes.

---

## Slice 1 — Make it survive "everything" (build now)

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
- No Business / MyFamily routing change (that's Slice 3's decision).
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

## Slice 2 — Read the documents (next)

Close F3. Before classification, build `contentText` for documents, not just images:
- PDF text layer (PDFKit; `ContentTagger` already does this. Hoist it so it runs once and both classification and tagging use it).
- **Vision OCR for scanned PDFs**, where the text layer is empty. `ContentDescriber` / `PDFCatalogIngester` already use `VNRecognizeTextRequest`, so reuse that.
- `.doc`/`.docx`/`.rtf`/`.txt` via the AppKit importers `ContentTagger` already uses.

Cache the text through `TagCache` (already keyed by path, modDate and size; it already stores `contentText`). A file is read once, ever, unless it changes. Page-cap large PDFs (first N pages) and record that the text is partial. Slice 1c's metrics show the cost.

---

## Slice 3 — Business / MyFamily routing (decision needed from Tim before briefing)

Today there's one `activeSchemaPolicy` (`OrganizerController.swift:332`). `DestinationSchema` is per-tenant, per-subtree (`DestinationSchema.swift:5`), but nothing decides *which tenant a file belongs to*. Options to decide between:
- **A. Rules first:** source folder or volume, known org names (the ObjectStore Organizations), and known clients (Finance/Valley Perinatal) map to Business. Everything else goes to MyFamily, with an "unsure" bucket for review.
- **B. A classifier over content** (needs Slice 2), with the rules as strong priors.
- **Recommended: A, then B,** with "unsure" always going to review, never auto-applied. A misrouted file crosses the tenant boundary, and that's the costliest mistake this pipeline can make.

Also in this slice: the tenant check on `HubRequestRouter`'s `.claimJob`/`.submitResult` (flagged in the shelved brief) doesn't matter while spokes do nothing. Re-check it if that changes.

---

## Slice 4 — Learn from Tim (the tenet)

Close F4. Read `FeedbackLog.events()` and the schema corrections into a **correction memory** that biases future proposals:
- "Files from this folder or pattern that Tim moved to X" become a learned rule with a confidence that grows with agreement and decays with contradiction.
- Learned rules are visible and revocable (what the system learned, and from which decisions).
- Measure it: the share of proposals Tim accepts unedited, tracked per night in the Slice 1c metrics file. **"Getting smarter" becomes a number that should rise.**
- Persist `schemaEdits` as corrections instead of clearing them on each fresh scan.

This is the slice that makes auto-apply trustworthy at higher volume. Until then, keep auto-apply thresholds where they are.

---

## After Slice 4 (noted, not scheduled)

- **Everything in the graph, not just what moved.** `bridgeToObjectGraph` is only called on apply (`:1104`, `:1529`). Files that are indexed but not yet moved never reach `ObjectStore`, so other verticals can't see them. Moving the bridge to happen at index time is the step toward "smarter across all verticals".
- **The morning digest** (Phase 3's other half): `nightSummary` plus Slice 4's accept-rate trend go into the dashboard's Priority glance (`ContentView.swift:483` stub).
- **Revisit distribution** only if Slice 1c's number says the Studio can't clear the backlog in an acceptable number of nights.

---

## Key paths (Slice 1)

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/CrawlLedger.swift` | AiOSCore | MODIFY — append-only persistence + one-time migration |
| `AiOSHub/AiOSHub/OrganizerController.swift` | AiOSHub | MODIFY — 1b (proposal durability), 1c (stage metrics), 1d (unmounted report), 1e (S1/S2 if cheap) |
| `AiOSCore/Sources/AiOSCore/TagCache.swift` | AiOSCore | MODIFY (only if doing S2) — hash cache |
| Tests for the above (find existing `CrawlLedger`/`OrganizerController` tests via grep) | both | MODIFY/ADD |
