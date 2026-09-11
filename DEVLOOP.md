# AiOS Local Dev Loop

**Goal:** let free local models (via Ollama + OpenCode) do most of the coding, and spend paid Claude only on blueprints and the things local models can't safely do. Everything below is set up and ready — this doc is how you drive it.

---

## The one rule that keeps this from producing garbage

> **Local models never touch bleeding-edge Apple API.**
> SwiftUI, Liquid Glass, FoundationModels, Swift 6.4 / iOS 27 SDK — the local models were trained *before* these existed. They will confidently write old, wrong code. Anything touching those goes straight to Claude (Tier 5). Local models only work inside **AiOSCore** (plain Swift logic + tests), where the APIs are stable and boring.

---

## What YOU do (only three things)

1. **Drop the idea** into `dev/REQUESTS.md` — one bullet, however rough.
2. **Decide the door** using the 10-second test below.
3. **Paste one command** (for the local door) or **talk to Claude** (for the blueprint door).

That's it. The machinery does the rest.

### The 10-second test: which door?

| If your request is… | Start at | Why |
|---|---|---|
| Vague, big, or new-API / any UI | **Claude** (Tier 0) | Needs a spec or knows the new APIs |
| A clear, bounded change to **AiOSCore** logic + tests | **Local** (Tier 1) | Stable APIs, local models are good here |

When unsure → Claude. A 30-second blueprint is cheap; a day of local models flailing on a vague ask is not.

---

## Where you set a request

Open **`dev/REQUESTS.md`** and add a bullet under `## Inbox`. Use this shape (the clearer the *done* line, the better local does):

```
- [ ] <what you want>. Files: AiOSCore/Sources/AiOSCore/<file>.swift. Done when: <a test passes / a function exists / behaviour X>.
```

Rough is fine — that's what the Claude door is for.

---

## The escalation ladder

Work climbs this ladder only when a tier fails its gate. It does **not** skip straight to Claude unless the rule at top says so.

| Tier | Who runs it | Kicks in when | You run |
|---|---|---|---|
| **0 — Blueprint** | **Claude** (this Xcode chat) | Idea is vague, big, UI, or new-API | Paste the idea to Claude; get back a spec written into `dev/REQUESTS.md` |
| **1 — Build** | **Qwen3-Coder 30B** (local, free) | Spec is clear + AiOSCore-only | `Tier-1 command` below |
| **2 — Gate** | **Xcode / swift** (deterministic) | After every build attempt | `Gate command` below — this is the truth, not the model's opinion |
| **3 — Review** | **Devstral 24B** (local, free) | Gate passes | `Tier-3 command` below |
| **4 — Escalate** | **Qwen3-Coder 32k** (local, free) — bigger context, same job | Qwen 30B failed the gate **2×** | `Tier-4 command` below |
| **5 — Rescue** | **Claude** (this Xcode chat) | Local failed the gate **2×**, OR new-API rule tripped | Paste the failing task + last error to Claude |

**Escalation triggers, in plain terms:**
- **2 failed gates → bump the model.** Qwen → DeepSeek-R1 → Claude. Never let a model retry forever.
- **New-API rule tripped → jump to Claude.** Skip Tiers 1–4 entirely.
- **Gate passes + review clean → stop.** Don't escalate working code.

---

## Copy-paste commands

All commands assume you're in the core package. First:

```sh
cd "/Volumes/AiOS Repository/code/AiOSCore"
```

> **Git lives per-package, not at the repo root.** AiOSCore (and AiOSHub, AiOSMyFamily) each have their OWN git repo; the monorepo root has none. So every `git` command below runs *inside* `AiOSCore/`. (Note: AiOSBusiness and AiOSOrchestrator have no repo yet — no rollback there.)

**Tier 0.5 — Checkpoint FIRST (do not skip).** A local model can make a confidently-wrong multi-file edit. You need a clean point to revert to, or a bad run is unrecoverable. Before turning Qwen loose:

```sh
git status --short        # if this lists changes, commit or stash them first:
git add -A && git commit -m "checkpoint before local-coder run"
```

Now Qwen's changes are an isolated diff you can throw away with `git restore .` if the run goes bad.

**Tier 1 — Build with Qwen3-Coder** (swap in your task, or point it at the inbox item):

```sh
opencode run "Implement this task in AiOSCore. Stay inside AiOSCore/Sources and AiOSCore/Tests. Use only stable Swift/Foundation APIs — no SwiftUI, no FoundationModels, no iOS 27-only API. Add or update unit tests. TASK: <paste your inbox bullet>" -m ollama/qwen3-coder:30b
```

**Tier 2 — Gate** (the deterministic check; run after every build):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta-b4.app xcrun swift build \
  && DEVELOPER_DIR=/Applications/Xcode-beta-b4.app xcrun swift test
```

- ✅ passes → go to Tier 3.
- ❌ fails → re-run Tier 1 **once** with the error pasted in. Still failing → Tier 4.

**Tier 3 — Review with Devstral:**

```sh
opencode run "Review the uncommitted changes for correctness, edge cases, and Swift style. List concrete problems only. Do not rewrite." -m ollama/devstral-small-2:24b
```

**Tier 4 — Escalate to Qwen3-Coder 32k** (more context, same family):

```sh
opencode run "Previous attempts failed the build/test gate. Here is the task and the last compiler error. Fix it. AiOSCore only, stable APIs only. TASK: <task>  ERROR: <paste error>" -m ollama/qwen3-coder-32k
```

> **Do NOT reach for `deepseek-r1:70b` interactively.** It thrashes this 64 GB machine (CPU-split, giant context). If a task genuinely needs it, run it alone as an overnight/batch job with nothing else loaded, and check `ollama ps` for thrash. For the normal loop, Tier 4 is Qwen 32k; if that fails the gate too, go to Claude (Tier 5).

**Tier 5 — Rescue:** come back to this Xcode chat, paste the task and the last error, and say "local is stuck." Claude grounds against the live SDK (DocumentationSearch), fixes it, runs the Xcode build gate, and commits.

---

## Why this saves money

Claude is only in the loop at **Tier 0** (short, cheap blueprint) and **Tier 5** (rare rescue). The expensive part — writing the volume of code — runs on local models for free. If the loop is working, most tasks never reach Tier 5.

Watch your local usage anytime with `opencode stats`.

---

## First run / sanity check

Before trusting the loop, do one throwaway pass end-to-end (Claude will pick a tiny AiOSCore task) to measure how often Qwen's output passes the gate on this repo. That number tells us the real split. See the "dry run" step Claude will propose.
