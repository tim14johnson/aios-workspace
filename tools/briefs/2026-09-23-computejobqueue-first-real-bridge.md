# CLI Brief — Phase 3, first real slice: bridge `ComputeJobQueue` to `ComputeWorker` for real, end to end

**Filed:** 2026-09-23
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 3 ("Idle/overnight distributed processing").
**Priority context:** Tim clarified tonight that "latent processing" means real idle-time work distributed across his already-paired devices (MBP/iPad/iMac) doing genuine AiOS work — NOT reviving `AiOSOrchestrator` (the separate, unproven overnight-coding dev tool, explicitly out of scope forever in this context). A research pass tonight found `ComputeJobQueue` (Hub-side) and `ComputeWorker` (spoke-side, macOS-only) are BOTH real, tested, and already wired to the same wire protocol (`HubRequest.claimJob`/`.submitResult` → `HubRequestRouter` → `ComputeJobQueue.shared`) — but `ComputeJobQueue.enqueue(_:)` has **zero real production call sites anywhere**. Its own doc comment self-admits this: *"spokes claim and complete them via the Hub's job API (to be wired in a later session)."* The mechanism is fully dormant end-to-end in production — exactly the same shape `ObjectStore` and `ConnectorSlot` were in before tonight's other slices. This brief wires the first real bridge.

**Grounded in real code, read in full tonight:**
- `ComputeJob` (`AiOSCore/Sources/AiOSCore/ComputeJob.swift`): `{id, type: JobType (.fileCrawl | .analyticsPass), targetPath: String, priority: Int (0-100, default 50), submittedAt}`.
- `ComputeJobQueue` (`AiOSCore/Sources/AiOSCore/ComputeJobQueue.swift`): real actor singleton `.shared`, priority-sorted `enqueue(_:)`/`claimNext()`/`complete(_:)`, `completedResults`/`inFlightJobs`/`pendingJobs` — all real, all simple, all correct.
- `ComputeWorker` (`AiOSCore/Sources/AiOSCore/ComputeWorker.swift`, `#if os(macOS)`): real actor, polls every 30s, only acts when `idle.isIdle` (a real `IdleDetector`, not a stub). `.fileCrawl` is a **fully working handler** — runs `SpotlightDiscoverer.discover(...)` with a filesystem-walk fallback, returns a real `FileIndexReport`. `.analyticsPass` is a **deliberate dead-end stub** — its handler literally returns an error saying `"analyticsPass jobs are executed by the hub, not the spoke"`. Don't touch `.analyticsPass` in this brief; it's stubbed by design, not by oversight, and fixing it would mean redesigning what that job type even means — a separate, bigger question.
- `NightScheduler` (`AiOSHub/AiOSHub/NightScheduler.swift`): real, working, entirely Hub-side/centralized — its `tick()`/`runNow()` call `OrganizerController.runNightPass()` directly, never touching `ComputeJobQueue`. This already does complete, valuable Tidy Files organization work on the Hub itself (not just discovery — actual file moves/schema application). **Do not replace or weaken this** — it stays exactly as it is.

**What this brief actually proves, and what it deliberately does NOT yet solve:** the goal is a genuine, live, end-to-end proof — Hub enqueues a real `.fileCrawl` job → an actually-idle paired spoke device claims it via `ComputeWorker`'s real polling loop → runs the real `SpotlightDiscoverer`-backed crawl → submits a real `FileIndexReport` back. What happens to that report once it's back (`ComputeJobQueue.completedResults` currently has no consumer at all — nothing reads it) and whether different devices should crawl different, device-local paths (an iPad's local storage vs. the Hub's own NAS view) to genuinely expand the known-file corpus, rather than redundantly re-crawling what the Hub already sees — these are real, good follow-on questions, **explicitly deferred**, not resolved here. This brief's job is narrower and more honest: prove the wire is real, additively, without touching what already works.

**Explicit non-goals:**
- Do NOT remove, replace, or weaken `NightScheduler.runNow()`'s existing direct call to `organizer.runNightPass()` — that's real, complete, working behavior. This brief is additive only.
- Do NOT fix `.analyticsPass` or redesign what it means. Leave it exactly as its own stub.
- Do NOT build any consumer for `ComputeJobQueue.completedResults` (i.e., don't try to merge a returned `FileIndexReport` into `TidyIndex`/`ObjectStore`/anything). That's real, valuable follow-on work, but a separate, bigger design question about cross-device corpus expansion — not this brief. It's fine and expected that the result just lands in `completedResults` and sits there, unconsumed, after this brief — that's the honest, narrow scope.
- Do NOT change `ComputeJob`/`ComputeJobQueue`/`ComputeWorker`'s existing, already-correct, already-tested internals. Consume as-is.
- Do NOT build any UI surfacing job status. If one's trivially cheap given what you're already touching, a one-line status text is fine, but don't treat it as required — the acceptance bar is the mechanism working, provable by test, not a polished UI.

---

## What to build

### 1. `NightScheduler` also enqueues a real `.fileCrawl` job

In `runNow()` (and/or `tick()` — your call on whether both paths should enqueue, or just one; `runNow()` is the simpler, more testable target since it's directly callable without waiting for the real time window), alongside the existing `await organizer.runNightPass()` call, add: `await ComputeJobQueue.shared.enqueue(ComputeJob(type: .fileCrawl, targetPath: <the same folder Tidy Files already organizes>, priority: <your call — this is background/low-urgency work, so a lower-than-default priority like 20-30 is probably right, but justify your choice>))`. Use `organizer.folderURL` (already confirmed to exist and be checked for `nil` in `runNow()`) as the real target path — mirror however the existing code converts it to the `String` `ComputeJob.targetPath` expects (check `URL`→`String` conversion conventions already used elsewhere in this codebase, e.g. `.path` vs `.absoluteString` — pick whichever the existing crawl code already uses for consistency, don't introduce a third convention).

### 2. Confirm the claim→execute→submit path actually works live, not just in isolation

`ComputeWorker` is already real and already polls `ComputeJobQueue` over the wire via `HubRequestRouter`. Your job isn't to build this — it's to prove, with a real integration-style test (not just unit tests of each piece in isolation), that a job enqueued by `NightScheduler` can actually be claimed and completed through the real `HubRequestRouter.handle(.claimJob)`/`.submitResult` path, ending up in `ComputeJobQueue.completedResults`. If a clean seam for this doesn't exist without deeper refactoring, say so honestly and settle for the strongest test you can write given the real, current shape of these types — don't force a fragile end-to-end test that doesn't reflect how the pieces are actually wired.

---

## Tests

- A test proving `NightScheduler.runNow()` (or `tick()`, whichever you chose) results in a real job landing in `ComputeJobQueue.shared.pendingJobs` with the correct `type`/`targetPath`/`priority` — not just that `runNightPass()` still gets called (that's already covered by existing tests, confirm they still pass).
- If feasible per the honesty clause above: a test proving that same job can be claimed via `HubRequestRouter.handle(.claimJob)` and completed via `.submitResult`, ending up in `completedResults`.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. Confirm via grep this doesn't require any AiOSBusiness/AiOSMyFamily change (expected: none — `ComputeWorker` is already wired identically in both, and this brief doesn't touch it).

---

## Acceptance criteria

1. `NightScheduler` enqueues a real `.fileCrawl` job for Tidy Files' actual configured folder, alongside (not instead of) its existing direct `runNightPass()` call.
2. Proven by test that the job genuinely reaches `ComputeJobQueue`'s real queue with correct fields.
3. `.analyticsPass` untouched. `runNightPass()`'s existing behavior untouched — confirmed by diff.
4. AiOSCore build+test green, AiOSHub build green.

---

## Commit

```
feat(compute): bridge NightScheduler to ComputeJobQueue — the first real, live job flowing through the dormant compute-distribution mechanism

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore (if any test infrastructure needs it), AiOSHub.

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSHub/AiOSHub/NightScheduler.swift` | AiOSHub | MODIFY — enqueue a real `.fileCrawl` job |
| `AiOSHub/AiOSHub/NightSchedulerTests.swift` (find real name via grep) | AiOSHub | MODIFY — new coverage |
