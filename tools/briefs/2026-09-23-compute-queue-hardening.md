# CLI Brief — Phase 3, step 1: harden `ComputeJobQueue`/`ComputeWorker` so the live test means something

**Filed:** 2026-09-23
**Status: SHELVED (2026-09-23) — do not build yet.** Tim decided the remote Macs will be reached by File Sharing (mounted on the Studio like the NAS) and the heavy pipeline runs on the Mac Studio. That leaves spokes with no compelling compute job right now. Keep this on file; revisit when a spoke job has a measured reason to exist (e.g. the Studio throughput test shows OCR backlog is too slow). Superseded by `2026-09-23-studio-pipeline.md`.
**Companion docs:** `docs/architecture/2026-09-22-back-to-basics-review.md` (Phase 3), `tools/briefs/2026-09-23-computejobqueue-first-real-bridge.md` (the slice this hardens — AiOSHub `59fa4af`).
**Priority context:** The first bridge proved enqueue → claim → complete through the real `HubRequestRouter`. A review of the landed code afterward found that the *live* test Tim is about to run (idle Apple-silicon Mac claims a job over the paired socket) can't produce a trustworthy result yet, and that the queue has no recovery behavior at all. This brief fixes exactly that — nothing wider. Consuming results (merging `FileIndexReport` into `TidyIndex`) is step 3 and is **not** this brief.

**Fleet fact that scopes this (decided 2026-09-23):** only Apple-silicon Macs run spokes. `ComputeWorker` is `#if os(macOS)` (iPad never claims), and the spoke apps resolve to `MACOSX_DEPLOYMENT_TARGET = 27.0`, so the old Intel Macs (2010 iMac, 2015 MBP, 2009 MBP) are out — their disks are being archived to the NAS instead. Don't add any Intel/legacy support.

---

## ⚠️ Decision point — Tim, before this goes to the CLI

**What should the night pass enqueue for spokes to crawl?** Today it enqueues one job for `organizer.folderURL.path` (`NightScheduler.swift:85`) — a path on the *Hub's* filesystem. A spoke crawls that literal path on its *own* disk (`ComputeWorker.swift:71`). Unless that folder is a NAS mount at the identical `/Volumes/...` path on both Macs, the spoke finds nothing.

| Option | What gets enqueued | Live-test result you'd see | Trade-off |
|---|---|---|---|
| **A. Keep `folderURL` only** | Unchanged | Likely the new "crawl root not found on this device" error (fix #1 below) — proves the wire + the error path, not a real crawl | Zero scope change |
| **B. NAS paths (recommended)** | One job per entry in `organizer.nasVolumePaths` (the NAS shares Tidy Files already knows about), *in addition to* `folderURL` | A real crawl with a non-zero file count, from any spoke that mounts the NAS at the same path | Spoke re-walks what the Hub's own night pass also walks — duplicate work, harmless for proving the mechanism. Actually *offloading* the Hub means changing `runNightPass()`'s roots, which is explicitly off-limits here |
| **C. Device-local logical scopes** | A scope like `home/Documents` each spoke resolves locally | Files the Hub has never seen | The real "corpus expansion" payoff, but it's a wire-format + design change — its own brief later |

**Recommendation: B now, C as its own later brief.** B is the smallest change that makes the live test show a real crawl, and it matches the NAS-as-archive direction. The report-size guard (fix #6) is what makes B safe on a big share.

**Tim's pick (2026-09-23): B now, C as its own later brief.** Goal behind it: centralize everything onto the NAS under the AiOS folder tree — deduped, properly named, foldered by Business / MyFamily. C is how spoke-local files get found; moving them to the NAS is a separate, later job type.

*(The rest of this brief assumes B. If A, skip the NAS-enqueue part of fix #2 and everything else stands.)*

---

## Grounded in real code, read 2026-09-23

- `ComputeJobQueue` (`AiOSCore/Sources/AiOSCore/ComputeJobQueue.swift`): in-memory actor. `enqueue` appends + sorts; `claimNext` moves pending → `inFlight: [UUID: ComputeJob]`; `complete` removes from `inFlight` and appends to `results` forever. No dedupe, no claim timestamps, no reclaim, no cap.
- `ComputeWorker.execute(.fileCrawl)` (`ComputeWorker.swift:70-93`): calls `SpotlightDiscoverer.discover(extensions: [], spotlightScopes: [root], walkFallbackRoots: [root])` with **no `CrawlLedger`**. So every job is a full, non-resumable walk. `error` is only set when Spotlight times out, so a missing root comes back as an empty "success". Spotlight returns nothing on the NAS (settled: `docs/architecture/2026-09-22-spotlight-schema-mapping.md`), so NAS jobs will always be walk-only. That's fine, but they won't be fast.
- `ComputeWorker.claimAndExecute` (`:52-61`): `_ = try? await client.send(.submitResult(result))` — **a failed submit is silently dropped.** The job stays in `inFlight` forever today, and after fix #3 it will be requeued.
- Transport (`AiOSCore/Sources/AiOSCore/Transport.swift:401-440`): frames are 4-byte length-prefixed with **no maximum**, and `receiveFramed` buffers the whole frame. A whole-volume `FileIndexReport` (one `FileRecord` per file, JSON-encoded) could be tens to hundreds of MB in one frame.
- `HubRequestRouter` (`AiOSCore/Sources/AiOSCore/HubRequestRouter.swift:81-87`): `.claimJob` → `claimNext()`, `.submitResult` → `complete(result)`. Neither goes through `authorizedTenant(...)` like the neighbouring cases do. **Flag only, don't fix here** (see "Out of scope").
- `NightScheduler.runNow()` (`AiOSHub/AiOSHub/NightScheduler.swift:67-91`) enqueues before `organizer.runNightPass()`. `OrganizerController.nasVolumePaths` (`OrganizerController.swift:287`) is the persisted NAS list.
- Hub UI: Night crawl controls live at `ContentView.swift:~1778-1786` ("Run Now" button). The status line goes here.
- Spoke `deviceID` is `identity?.name ?? tenant.rawValue` (`AiOSBusiness/AiOSBusiness/SpokeController.swift:283`, same in AiOSMyFamily). It's human-readable enough for the status line.
- Existing tests: `AiOSHub/AiOSHubTests/NightSchedulerTests.swift` (`.serialized` suite on the shared singleton). Fix #2's dedupe **will** change what repeated `runNow()` calls leave in `pendingJobs`. Update those tests deliberately; don't weaken them.

---

## What to build

### 1. Spoke: missing crawl root is an error, not an empty success
In `ComputeWorker.execute(.fileCrawl)`, before calling `discover`, check that `job.targetPath` exists **and is a directory** on this device. If not, return a `ComputeJobResult` with `fileIndex: nil` and an explicit error, e.g. `"crawl root not found on this device: <path>"`. The Hub side must be able to tell this apart from "crawled, found 0 files".

### 2. Hub: dedupe on enqueue (+ NAS targets if option B)
- `ComputeJobQueue.enqueue` becomes a no-op (returns `false`, or a discardable `Bool`, your call) when a job with the same `(type, targetPath)` is already **pending or in flight**. Don't dedupe against completed results; tomorrow night *should* enqueue again.
- *(Option B)* `NightScheduler.runNow()` also enqueues one `.fileCrawl` job (priority 25, same reasoning as the first slice) per entry in `organizer.nasVolumePaths`, skipping any that equal `folderURL.path`. The `runNightPass()` call and its behavior stay unchanged. Confirm by diff again.

### 3. Hub: in-flight lease + reclaim
- Record the claim time for each in-flight job.
- In `claimNext()`, before returning the next pending job, lazily move any in-flight job older than a lease back to pending. Don't add a timer; the lazy sweep is enough and keeps the actor simple.
- **Lease default: generous (e.g. 2 h)**, injectable via `init` for tests. A walk of a large NAS share with no ledger is slow, and too short a lease makes two spokes crawl the same share at once.
- **Late results:** if `complete(_:)` receives a result for a job that was requeued (it's back in pending) or re-claimed, accept the result and remove that job from pending/in-flight. First result wins; don't do the work twice. If the job ID is completely unknown, still record the result but don't crash.
- Cap retries: after N reclaims (e.g. 3), drop the job with a synthesized failed `ComputeJobResult` (`error: "abandoned after 3 lease expiries"`) instead of requeuing forever. This is what breaks the "silent submit failure → requeue → another full walk → silent failure" loop.

### 4. Hub: cap `completedResults`
Keep the most recent N (e.g. 50), dropping oldest first. It's still in memory only. Persistence waits for step 3, when results actually get consumed. Don't add persistence here.

### 5. Hub: one status line
Add a small read-only snapshot to `ComputeJobQueue` (e.g. `status() -> (pending: Int, inFlight: Int, completed: Int, last: ComputeJobResult?)`) and show one line under the Night crawl controls:
`Compute: 1 pending · 0 running · 3 done (last: <spokeID>, 1,204 files)`. If the last result has an error, show that instead of the count, e.g. `(last: <spokeID> — crawl root not found on this device)`.
Refresh it with a view-scoped `.task` poll (a few seconds is fine), **not** `NightScheduler`'s 5-minute loop. Tim needs to watch this change during the live test.

### 6. Spoke: bound the report size
In `ComputeWorker`, if the walk returns more than a cap (e.g. 50,000 records), send the first N and set `error` to say it was truncated (e.g. `"truncated at 50000 of <total> records"`). A frame-size limit in the transport is the more principled fix, but it's shared plumbing every request uses, so it's out of scope here. The cap is a local guard that makes option B safe on a big share.
Also log a failed `.submitResult` send instead of `try?`-swallowing it, using whatever logging convention `ComputeWorker`/`SpokeController` already use (check, don't invent one). Keep the fire-and-forget behavior; the lease in fix #3 handles recovery.

---

## Tests

AiOSCore (`ComputeJobQueue`, `ComputeWorker` where testable without a live socket):
- Enqueue the same `(type, targetPath)` twice → one pending job. Different path or different type → two jobs. Same path after completion → enqueues again.
- A claim older than an injected short lease is reclaimed by the next `claimNext()`. A fresh claim is not.
- A late result for a reclaimed job: recorded once, job removed from pending, not handed out again.
- After the retry cap, the job is gone from pending/in-flight and a failed result is present.
- `completedResults` never exceeds the cap; the oldest results are dropped first.
- Missing-root check: if `execute` isn't reachable without a `PairedHubClient`, extract the root-validation into a small internal/static function and test that. Don't build a live-socket harness; that's still out of scope.
- Report-cap truncation, via the same extraction approach if needed.

AiOSHub (`NightSchedulerTests.swift`):
- Update the existing enqueue tests for dedupe (two `runNow()` calls → still one pending job for `folderURL`).
- *(Option B)* With `nasVolumePaths` set, `runNow()` enqueues one job per NAS path, skips one that duplicates `folderURL`, and `runNightPass()` still runs.
- The existing `HubRequestRouter` claim → submit → `completedResults` integration test still passes.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Also build AiOSBusiness and AiOSMyFamily for macOS. Fixes #1 and #6 change `ComputeWorker` in AiOSCore, and both spokes compile it. Zero errors, zero new warnings.

---

## Acceptance criteria

1. A spoke crawling a path that doesn't exist on its disk reports a clear error that the Hub can tell apart from an empty crawl.
2. No duplicate pending/in-flight jobs for the same `(type, targetPath)`.
3. Stuck in-flight jobs come back to the queue after a lease, give up after a retry cap, and late results are recorded once without redoing the work.
4. `completedResults` is capped.
5. The Hub shows a live one-line compute status under Night crawl.
6. Oversized crawl reports are truncated with an explicit error. Failed submits are logged, not swallowed.
7. *(Option B)* NAS paths are enqueued. `runNightPass()` is unchanged, confirmed by diff.
8. AiOSCore build+test green. AiOSHub, AiOSBusiness and AiOSMyFamily build green.

---

## Out of scope — flag, don't fix

- **Tenant authorization on `.claimJob`/`.submitResult`.** Any paired spoke, business or family, can claim any job and submit a result for any job ID. Once step 3 merges reports into `TidyIndex`, that becomes a real integrity issue. It belongs with the tenant-isolation work (`tools/briefs/2026-09-23-tenant-isolation-fix.md`), not here.
- A transport-wide maximum frame size.
- Queue persistence across Hub restarts.
- Consuming `FileIndexReport` (step 3), the morning digest (step 4), device-local scopes (option C), `.analyticsPass`.
- Intel/legacy Mac support, a Synology DSM/Universal Search connector (reviewed and parked 2026-09-23).

---

## Live test (Tim, after this lands)

1. Rebuild and redeploy the macOS spoke (Business or MyFamily) on an Apple-silicon Mac that mounts the NAS at the same `/Volumes/...` path as the Hub.
2. Leave that Mac idle. `ComputeWorker` polls every 30 s and only claims when `IdleDetector` says idle.
3. Press **Run Now** on the Hub.
4. Watch the status line go `1 pending` → `1 running` → `1 done (last: <device>, N files)` with N > 0. An error in that line is also a useful result; it tells you which part failed.

---

## Commit

```
feat(compute): harden ComputeJobQueue/ComputeWorker — dedupe, in-flight lease + retry cap, result cap, missing-root error, report-size guard, live Hub status line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

Repos touched: AiOSCore, AiOSHub (AiOSBusiness/AiOSMyFamily: rebuild only, no source changes expected).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/ComputeJobQueue.swift` | AiOSCore | MODIFY — dedupe, lease/reclaim, retry cap, result cap, status snapshot |
| `AiOSCore/Sources/AiOSCore/ComputeWorker.swift` | AiOSCore | MODIFY — missing-root error, report cap, log failed submit |
| `AiOSCore/Tests/...` (find the existing ComputeJobQueue tests via grep) | AiOSCore | MODIFY/ADD |
| `AiOSHub/AiOSHub/NightScheduler.swift` | AiOSHub | MODIFY — (option B) enqueue NAS paths |
| `AiOSHub/AiOSHub/ContentView.swift` (~L1778) | AiOSHub | MODIFY — status line |
| `AiOSHub/AiOSHubTests/NightSchedulerTests.swift` | AiOSHub | MODIFY — dedupe + NAS coverage |
