# Library, model third: per-job checkout (built 2026-09-24/25)

**Status:** Slice 1 built on branch `feature/model-library` in AiOSCore, AiOSHub, the root repo and docs. **Not merged.** The launchd side (on-demand plist, start script) is **already live** on the Studio, because it lives outside git. See "Operational changes".

**Why:** the always-on brain server (`com.aios.brain-server`, `RunAtLoad` + `KeepAlive`, 8 GB prompt cache) held Qwen3.8-27B resident for 15 h: 26 GB, 15 GB of it compressed, swap in use, and a beachballing Studio. Its log showed a Metal `Insufficient Memory` crash at 07:32 that left the process alive, holding memory, and serving nothing. The 09-23 prompt budget (`RemoteAnalyticsEngine` batching) bounded *requests*; nothing bounded *residency*.

**Tim's direction:** the orchestrator decides everything per job. It checks out the right model, launches it, runs the job, checks it back in, and decommissions it. Nothing persists while nothing runs. Choices come from job requirements × available hardware × model capability, with no hard-coded "27B means overnight" rules, so a 512 GB Studio makes different, correct choices from the same code. Capability is inferred up front and measured afterwards. The Dashboard button is an admin failsafe, not the normal path. Overnight heavy lifting stays first-class.

## What was built

**AiOSCore `Sources/AiOSCore/ModelLibrary/`**
- `ModelScheduler` (pure): `decide(job, catalog, hardware, resident, outcomes)` returns **run now** (model + prompt-cache size), **wait for the overnight window** (a deferrable job that doesn't fit now), or **unavailable** (the caller falls back). Budgets are fractions of *live* RAM: 40% by day and 80% off-hours (overnight, user idle, calm memory), minus a 6 GB reserve. Critical pressure allows no new loads. Every decision carries a rationale string.
- **Fitness is a prior plus measured outcomes.** `ModelTraits` is inferred from `config.json`, the name and the weights on disk:
  - dense vs MoE, judged by dense-equivalent size √(total × active)
  - coder vs general
  - quantization
  - context length
  - KV bytes per token (hybrid-attention models count only full-attention layers)
  
  The prior is blended with `ModelOutcomeLedger` history per (model, role). The prior is worth 3 runs, so measured results take over quickly.
- **Prompt cache per checkout.** 2 GB by day. Off-hours it flexes into the spare budget (cap 16 GB). `mlx_lm.server` fixes `--prompt-cache-bytes` at launch, so it's decided per load, not resized live.
- `ModelLibrary` (actor):
  - leases, and a different model never swaps out from under a running job
  - idle offload after 10 min with no lease and no server CPU activity
  - lease files from other processes, checked by pid
  - heartbeat file, shutdown hook
  - admin `forceLoad` / `offload`
  - a **checkout transport**: routes each request to the scheduled model and records the outcome. Requests for another endpoint (e.g. Ollama) pass through untouched.
- `LaunchdModelServer`: writes `brain-model.txt` / `brain-cache-bytes.txt`, kickstarts the agent and waits until the model answers. launchd stays the process owner.
- `ModelProfile` (the existing routing type) gained `footprintBytes` + `traits`. Library entries: `.branch` = the Hub server, `.device` = Apple Foundation Models. No parallel model type.
- Includes the Virtual IT pieces from `docs/cli-virtual-it-process-watchdog.md` that had been left uncommitted (`LaunchAgent`, `ManagedProcess`, `ProcessWatcher*`). The watchdog cap is now 2 GB, the library's baseline.

**AiOSHub**
- `HubModelLibrary`: the one library, plus the Hub's job requirements. The catalog is `models/hf/hub` (by repo id), `mlx-models/hub` and `Model-Library/` (by path), plus Foundation Models when available. The overnight window is 00–06. `HubAppDelegate` starts the idle loop at launch and checks in at quit.
- Checked out: live spoke analysis (`analysis`, minimum fitness 0.5, 24k context, interactive), the Brain eval (pinned model), interview rewrites and local cover letters (`writing`, 0.3). Rewrites and cover letters credit the model that actually answered.
- Dashboard **Model library** row: loaded model, cache, footprint, leases, the last decision's rationale, the offload countdown, and a collapsed **Admin override** (load now / offload now / rescan). "Over expected size" is judged against weights + cache for the current load, not the watchdog's fixed 30 GB.

**Root repo:** `tools/lib/brain-lease.sh`, and `overnight-queue.sh` holds a lease for its whole run.

## Operational changes (outside git, already live)
- `~/Library/LaunchAgents/com.aios.brain-server.plist`: `RunAtLoad` and `KeepAlive` removed. The agent stays loaded but dormant until kickstarted. Backup: `~/Library/Application Support/AiOS/com.aios.brain-server.plist.bak-20260924`.
- `~/Library/Application Support/AiOS/start-brain-server.sh`:
  - reads `brain-cache-bytes.txt` (default 2 GiB)
  - keeps spaces inside model paths (the old `tr -d '[:space:]'` broke `/Volumes/AiOS Repository/...` paths)
  - sets `HF_HUB_OFFLINE=1`
  
  Backup: `.bak-20260924`.
- The manual twin `/Volumes/AiOS Repository/tools/start-brain-server.sh` now uses a 2 GiB cache.
- **Consequence:** nothing answers on :8080 until something checks a model out. The Hub build running before this change (it calls :8080 directly) gets no answer and falls back to rules-only analysis. Relaunch on this branch's build: a Release build outside Xcode, per the 09-24 follow-up.

## What it decides on this Studio (probe, 09-24 evening, apps open)
- **By day:** budget ≈ 17.5 GB. Spoke analysis with the 27B needs 18.2 GB, so it falls back to rules. A deferrable job waits for the window.
- **Overnight:** budget 44 GB. The 27B runs with a 16 GB cache.
- A coder model (Devstral, prior 0.47) was eligible for analysis at a 0.45 minimum, which is why analysis now requires 0.5.

## Verification
- AiOSCore 1,034 tests pass on the branch. **Merged with `feature/slice5-org-home` in scratch worktrees:** AiOSCore 1,053 pass, AiOSHub 60/60. The only warnings are the pre-existing `TagCacheTests.swift:29` and `ResumeCorpusCollectorTests.swift`.
- Hub build: 0 errors, 0 new warnings. `check-hygiene.sh` passes.
- **Live end to end:** script lease → launchd → the 27B answering in 25 s with a 2 GB cache → released on exit → offloaded. The first attempt caught a design flaw: the helper trusted "an AiOSHub process exists", but the running Hub was an old build with no library. The helper now trusts only a fresh library heartbeat.

## Merge notes
- **Stacking:** AiOSCore: `main → fix/tidy-placement-and-brain-budget → feature/tax-checklist → {feature/slice5-org-home, feature/model-library}`. AiOSHub: `main → fix/tidy-placement-and-brain-budget → {feature/slice5-org-home, feature/model-library}`. Slice 5 and the library merge without conflicts. The only shared file is AiOSHub `ContentView.swift`, and it auto-merges.
- **The Hub doesn't build from a clean checkout of `main` or `fix/tidy-placement-and-brain-budget`.** `ContentView` references `BrainServerAdmin`, which was never committed until this branch. Merge `feature/model-library` together with (or right after) `fix/tidy-placement-and-brain-budget`, before building `main` from clean.
- The AiOSCore branch carries `feature/tax-checklist` (`aa708e9`) underneath it, as Slice 5 does.

## Open (next slices, in order)
1. **Deferred jobs aren't queued yet.** A deferred job currently fails over like any other failure, and nothing re-runs it in the window. Next: a persistent deferred-job queue (extend `ComputeJobQueue`) that `NightScheduler` drains overnight, so heavy analysis actually happens overnight.
2. **The outcome score is transport-level** (answered or failed). Wire the grounding gate's keep rate (claims surviving "no citation, no claim") as the real quality score, then user accept/dismiss (`ImplicitInteractionLog`).
3. **Admin gating:** the Hub has no signed-in user, so the override is hidden, not role-gated. Role gating needs a Hub sign-in concept (`Role.owner/.admin` exist in `AccessControl`).
4. **Retire `ModelRotationController`.** It still kills and starts servers outside the library (Devstral :8082, Flash-Next via `mlx-serve`).
5. **Co-residency** (several models at once) when the budget allows, so bigger hardware runs more at once. Needs a port per resident model. Single-resident is just the 64 GB outcome.
6. **Other runtimes:** llama.cpp / Flash-Next (`context/memory/aios-hub-server-picker.md`) would be a second `ModelServerControl`.
7. **Runbook caveat:** `tools/OVERNIGHT-RUNBOOK.md` suggests moving Qwen3.8-27B out of the HF cache into `Model-Library/`. The library would then serve it by path, not by repo id. `overnight-queue.sh`'s `EXECUTOR_MODEL=mlx-community/Qwen3.8-27B-4bit` must change to that path, or with `HF_HUB_OFFLINE=1` the load fails.
