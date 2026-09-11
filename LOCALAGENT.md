# AiOS Local Coding Agent — how to use it (and save Claude for the hard stuff)

The goal: do most coding for free on your own Mac with the local model, and only spend Claude
when the local model gets stuck. This is the same tiered-handoff idea as the whole product,
applied to your own dev work.

## Preferred Xcode path

For Xcode app targets, use the repository-local Xcode 27 toolchain and OpenCode ACP workflow in
[`XCODE_LOCAL_AGENT_SETUP.md`](XCODE_LOCAL_AGENT_SETUP.md). It supersedes the old assumption that
Claude-in-Xcode is required for app work: local ACP is now the default, with cloud escalation only
when the documented local verification loop produces evidence that it is needed.

## One-time facts
- Primary local model: `qwen3-coder:30b` served by Ollama on `http://127.0.0.1:11434`.
- Optional local model: `Qwen3-Coder-30B-A3B-Instruct-4bit` served by oMLX on `http://127.0.0.1:18080/v1`. It is opt-in for OpenCode/Xcode evaluation; unload the Ollama 30B model before starting it, and verify model-proposed source references before editing.
- Agent: Aider (installed at `~/.local/bin/aider`).
- Launcher: `tools/aicode` in this repo.
- Model tuning lives in `AiOSCore/.aider.model.settings.yml` (big context + whole-file edits —
  do not remove; without it the agent silently truncates and "succeeds" while doing nothing).

## Frontline execution and senior-council gate

The local models are frontline staff, not the final authority. `tools/aicode` lets Qwen edit and test only the named `AiOSCore` files, then runs the full core verification and stages the permitted diff. It **never commits**. Start from a clean `AiOSCore` working tree so every staged line can be attributed to the current task.

```bash
cd "/Volumes/AiOS Repository/code"
bash tools/aicode "Add X to FileOrganizer and a focused test. Edit only the named files." AiOSCore/Sources/AiOSCore/FileOrganizer.swift AiOSCore/Tests/AiOSCoreTests/FileOrganizerTests.swift
```

Qwen is the default executor. To give the same bounded task to Devstral instead, prefix the command with `AICODE_MODEL=devstral-small-2:24b`; the staging and senior-gate rules do not change.

After a verified run, the next command is not `git commit`; it is the senior gate:

```bash
SENIOR_COUNCIL_SEND=1 python3 tools/senior-council.py gate --repo AiOSCore
```

The gate sends only the staged diff and complete changed text files to the configured senior reviewers, Claude and Perplexity. It returns exit code 0 only when **every** reviewer returns `VERDICT: PASS`; otherwise the staged work remains uncommitted and the report explains what the frontline executor must fix. API keys belong only in the git-ignored `.aios.env` file, created from `.aios.env.example`.

For a no-code-reading finalization step, use the protected committer instead of running `git commit` yourself. It re-runs the gate against the current staged diff and commits only on a fresh two-reviewer pass:

```bash
SENIOR_COUNCIL_SEND=1 bash tools/finalize-ai-change.sh \
  --repo AiOSCore \
  --message "Describe the verified change"
```

### Blueprint escalation

When Qwen and Devstral cannot produce a credible, testable solution proposal, ask the senior council for a blueprint before local implementation. First run the local council over the precise files, then send its report and only the relevant complete source files:

```bash
SENIOR_COUNCIL_SEND=1 python3 tools/senior-council.py blueprint \
  "context/Perplexity notes/local-model-council/<local-report>.md" \
  AiOSCore/Sources/AiOSCore/RelevantFile.swift
```

The senior council proposes the blueprint, invariants, allowed-file boundary, test plan, and rollback plan. It does not edit or commit. Pass that blueprint back to the local executor as its bounded task, then run the senior gate against the staged result before committing.

`tools/aicode-auto` is intentionally paused until it is rebuilt around this same gate; it must not bypass senior review by auto-committing.

## What the local agent is good at vs. not (be realistic)
GOOD (hand these to `aicode`):
- AiOSCore package work: logic, small functions, refactors inside a file, anything `swift test` can verify.

USE OPENCODE ACP IN XCODE FIRST (not the terminal launcher):
- Xcode **app** targets (AiOSHub / AiOSBusiness / AiOSMyFamily): building/running, the Simulator,
  entitlements, Info.plist, app icons, and SwiftUI that must be rendered. Follow
  `XCODE_LOCAL_AGENT_SETUP.md` and start with a plan-only, project-scoped local ACP request.

ESCALATE ONLY WITH EVIDENCE:
- Hard multi-file/architecture changes, tricky edge cases, or an app-target failure that remains
  reproducible after the local ACP plan and Xcode 27 verification loop. Send the smallest useful
  diff and failure output, not an open-ended prompt.

## Escalation workflow
When `aicode` ends FAILING or made no commit:
```bash
cd "/Volumes/AiOS Repository/code"
git -C AiOSCore diff                         # see what it tried
bash tools/with-xcode27.sh scripts/verify.sh core  # reproduce with the pinned toolchain
```
First decide whether a narrowly scoped local retry or `tools/aicode-review` can resolve it. For an
app-target issue, use the local OpenCode ACP agent in Xcode 27 with the exact failure output. Use a
cloud model only if that local loop remains blocked, and provide the small diff plus the last relevant
verification output. Because everything is under git, a bad local-agent change is always revertible:
`git -C AiOSCore checkout -- <file>`.

## "How do I switch this conversation to the local agent without losing context?"
You do not move a chat; you move the **minimum useful context** into repository-owned files:
1. The **repo** itself (`/Volumes/AiOS Repository/code`) — source, tests, workspace, and git history.
2. The **agent contract** — `AGENTS.md`, `LOCALAGENT.md`, and `XCODE_LOCAL_AGENT_SETUP.md`.
3. The **durable project context** — a deliberately selected architecture, decision, or backlog file
   kept under the repository's `context/` area rather than inside an Xcode/Claude configuration folder.
4. The **docs** (`/Volumes/AiOS Repository/docs`) — specifications, ExSellerator, and requirements.

`tools/aicode` explicitly reads `AGENTS.md` and `LOCALAGENT.md` on every local run. It deliberately
does **not** read Xcode's Claude-specific configuration directory. Add a `--read <file>` only when a
small, stable, repository-owned context file is essential to the task; do not turn every run into a
giant context dump.

If a cloud escalation is justified, provide the small relevant diff, verification output, and only the
specific durable context needed for the decision. Local context and commits remain the source of truth.

## The honest bottom line
Use `aicode` for bounded AiOSCore logic/tests and OpenCode ACP in Xcode 27 for app work. The local
workflow now owns the default path; cloud is a deliberate escalation for a verified local block or a
higher-judgment review. As local reliability and the validation automation improve, the share that
needs cloud assistance shrinks — that shrinking share is the product thesis, proven on your own
workflow.
