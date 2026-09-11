# Xcode 27 Local Agent Setup

## Purpose

Make local AI the default for AiOS development on this Mac Studio. The intended stack is:

1. **Xcode 27 beta b4** for all AiOS build and test commands that need Swift 6.4 and project-format 110 support.
2. **Ollama** for locally served models.
3. **OpenCode ACP** for an external agent that can use Xcode's project-aware build, test, debugger, simulator, and filesystem tools.
4. **Aider + Qwen3-Coder 30B** as the fast terminal fallback for small, scoped `AiOSCore` work.
5. Cloud models only for a clearly documented escalation, not the default implementation path.

Apple documents both locally hosted chat providers and external ACP agents in Xcode 27. The local chat-provider path uses a standard OpenAI-compatible API, while ACP enables a tool-using agent workflow. Read the official [Xcode local-model session](https://developer.apple.com/videos/play/wwdc2026/232/), [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes), and [external-agent access guide](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode) before changing permissions.

## Safety Boundary

This repository pins its own developer directory to:

```text
/Applications/Xcode-beta-b4.app/Contents/Developer
```

That selection lives in `scripts/lib/toolchain.sh`. It does **not** run `xcode-select` and therefore does not change the Mac-wide Xcode choice. A controlled upgrade can set either environment variable for one command:

```bash
AIOS_XCODE_APP="/Applications/Xcode-beta-b4.app" bash tools/with-xcode27.sh
AIOS_DEVELOPER_DIR="/Applications/Xcode-beta-b4.app/Contents/Developer" bash tools/with-xcode27.sh
```

Do not change the default toolchain path until the candidate Xcode has passed the AiOS verification commands below.

## Verify the Toolchain

From the repository root:

```bash
cd "/Volumes/AiOS Repository/code"
bash tools/with-xcode27.sh
bash tools/with-xcode27.sh scripts/verify.sh core
```

The first command should print the repository developer directory, Xcode 27, and Swift 6.4. The second runs the existing hygiene, warning-free build, and test gates against `AiOSCore`. `scripts/check-build.sh`, `scripts/check-tests.sh`, and `tools/aicode` already use this toolchain automatically, so the wrapper is primarily a transparent diagnostic and a safe way to run ad-hoc commands.

## Configure Xcode 27 for Local AI

### Open the correct Xcode

1. Quit other Xcode instances that may be controlling the project.
2. Launch `/Applications/Xcode-beta-b4.app` and open `AiOS.xcworkspace` from `/Volumes/AiOS Repository/code`.
3. Confirm a build uses the Xcode 27 beta before asking any agent to modify code. The repository scripts above are the source of truth, not the global `xcodebuild` command.

### Add a locally hosted chat provider

1. In Xcode 27, open **Settings → Intelligence**.
2. Add a **Locally Hosted** chat provider.
3. Point it to the loopback Ollama OpenAI-compatible endpoint: `http://127.0.0.1:11434/v1`.
4. Select the local coding model you have deliberately tested for this route. Start with `qwen3-coder:30b`; do not silently substitute a cloud-backed provider.
5. Send a non-editing test question first, such as: “Summarize the active scheme and name no files outside the workspace.”

Apple's local-model demonstration uses MLX-LM, but the Xcode requirement is a local service implementing the expected chat-completions API. Ollama documents its OpenAI compatibility and OpenCode integration at [Ollama API compatibility](https://docs.ollama.com/capabilities/openai) and [Ollama + OpenCode](https://docs.ollama.com/integrations/opencode). Keep this endpoint loopback-only; do not expose port 11434 to the LAN merely to make Xcode work.

### Optional oMLX coding provider

The project now also exposes the tested MLX build of Qwen3-Coder 30B through oMLX at `http://127.0.0.1:18080/v1`. It is deliberately separate from the Ollama provider in `opencode.json`, so choosing it does not silently change the current local default. oMLX is a local inference runtime documented at [oMLX](https://github.com/jundot/omlx).

1. Before starting oMLX, unload the 30B Ollama model with `ollama stop qwen3-coder:30b`; do not keep both 30B runtimes resident on this 64 GB Mac.
2. In a dedicated Terminal, run `bash tools/start-omlx-qwen3-coder-30b.sh` from the repository root and leave it running.
3. For a separate Xcode locally hosted provider, use `http://127.0.0.1:18080/v1` and select `Qwen3-Coder-30B-A3B-Instruct-4bit`. In OpenCode, select the clearly named **oMLX (local, opt-in evaluation)** provider.
4. Start with plan-only or read-only work. Both local runtimes reached correct complete-file conclusions but supplied unreliable source line numbers, so verify every proposed patch against the actual file and the Xcode 27 test loop.

### Add OpenCode as an ACP agent

1. In **Settings → Intelligence**, add an external ACP agent.
2. Xcode's current form accepts an executable and optional interpreter, but not ACP arguments. Use the repository-owned launcher instead:

   ```text
   Name:        AiOS Local OpenCode
   Executable:  /Volumes/AiOS Repository/code/tools/xcode-opencode-acp.sh
   Interpreter: /bin/bash
   ```

   The launcher runs `/opt/homebrew/bin/opencode acp --cwd "/Volumes/AiOS Repository/code" --pure`, keeping the server project-scoped and free of external plugins.
3. Give the agent only the AiOS workspace and the project-scoped permissions it needs. Permit build, test, simulator, debugger, and repository-file actions only after you confirm the agent is operating inside `/Volumes/AiOS Repository/code`.
4. Keep the Xcode project open while working. Apple's agent bridge is project-aware and expects the project to be available.
5. Verify the connection with a read-only request first: “Create a plan only. List the affected files and the exact build/test command; do not edit.”

OpenCode's ACP entry point is documented at [OpenCode ACP](https://opencode.ai/docs/acp/). Xcode's permission and tool-customization model is described in [Extending and customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents/).

## Local-First Working Contract

Use this operating sequence for every non-trivial change:

1. **Plan locally**: ask OpenCode ACP for a plan, exact files, and a verification command. Do not let it begin with an unrestricted implementation request.
2. **Scope narrowly**: ask it to change one target or coherent feature slice, not “fix the app.” Existing app working trees are dirty, so do not authorize broad cleanup or formatting changes.
3. **Implement locally**: choose the ACP agent for Xcode app targets and Aider for bounded `AiOSCore` edits.
4. **Verify with Xcode 27**: run `scripts/verify.sh <target>` before calling the work done. Treat warnings as failures.
5. **Stage, do not commit**: the local executor may stage only the named, verified files. Before any commit, run `SENIOR_COUNCIL_SEND=1 python3 tools/senior-council.py gate --repo <git-repository>`. The gate sends only the staged diff and complete changed text files to Claude and Perplexity, and passes only when every senior reviewer returns `VERDICT: PASS`.
6. **Escalate for a blueprint**: when Qwen/Devstral cannot form a credible plan, use `tools/senior-council.py blueprint` with the local report and tightly scoped source files. Senior models propose the blueprint and test boundary; local models execute it. Do not hand a cloud model the entire project or an open-ended “make it work” prompt.

### Use the local council from Xcode

The Xcode **Locally Hosted** chat provider selects one model at a time. It is useful for a quick, direct question, but it cannot by itself sequence Qwen and Devstral. The multi-model council is run through the project-owned OpenCode ACP agent.

1. In the Xcode agent picker, select **AiOS Local OpenCode** rather than the single-model locally hosted chat provider.
2. For the first test, send this exact plan-only request and replace the bracketed text:

   ```text
   Do not edit, stage, or commit. Run the project local council for this request:
   [describe the desired change]

   First identify the smallest complete source files needed. Then run
   `bash tools/local-model-council.sh` using only those files. Report the Qwen proposal,
   Devstral critique, Qwen adjudication, risks, and the exact verification boundary.
   ```

3. The council command must return a report under `context/Perplexity notes/local-model-council/`. Do not approve implementation until it states `DECISION: PROCEED` and names the files and tests.
4. If Xcode exposes the OpenCode slash-command menu, use `/council <request>` instead. OpenCode documents project commands in `.opencode/commands/`, but slash-command availability through ACP is not yet verified here; the explicit prompt above is the reliable ACP fallback.
5. After the local council report, authorize one local executor only. For a difficult plan that remains unresolved, explicitly request the senior blueprint; otherwise keep Claude and Perplexity out of the run.

### Terminal fallback for AiOSCore

```bash
cd "/Volumes/AiOS Repository/code"
tools/aicode "Add the requested behavior and a focused test; edit only these files." \
  AiOSCore/Sources/AiOSCore/Example.swift \
  AiOSCore/Tests/AiOSCoreTests/ExampleTests.swift
```

`tools/aicode` now supplies repository-owned `AGENTS.md` and `LOCALAGENT.md` instructions instead of reading Xcode's Claude-specific configuration folder. It uses the pinned Swift 6.4 toolchain, rejects unexpected Swift-file edits, and runs `scripts/verify.sh core` after a commit.

## Prompt Templates

### Plan-only prompt

```text
Plan only. Do not edit. Stay inside the currently open AiOS workspace.
Identify the minimal files, risks, and the exact Xcode 27 build/test command.
Respect AGENTS.md. Do not change unrelated files, project settings, dependencies, or git history.
```

### Implementation prompt

```text
Implement only the approved plan for <target>. Edit only: <file list>.
Use Swift concurrency rules in AGENTS.md. Before finishing, run <verification command>.
Report changed files, command output, warnings, and any reason to stop rather than guessing.
```

### Escalation packet

```text
Goal: <one sentence>
Constraints: local-first; no dependency or project-setting changes; edit only <files>.
Failure: <exact last 40 lines of build/test output>
Diff: <small relevant diff>
Question: <specific decision or repair request>
```

## Non-Negotiables

- Do not use a Claude-powered Xcode agent as the ambient default.
- Do not grant an agent access beyond the open AiOS workspace unless you explicitly intend it.
- Do not let an agent modify the dirty app-target working trees without a file list and an approved plan.
- Do not use a generic source-editor extension as a substitute for Xcode 27 ACP tools.
- Do not deploy or publish an Ollama endpoint to the network for convenience.
- Do not change `xcode-select` for this workflow.

## When Cloud Is Justified

Escalate only when the local agent has a reproducible failure after the scoped plan and verification loop, or when the change requires judgment beyond local-model reliability: cross-target architecture, security review, production data boundaries, difficult concurrency bugs, or a reviewer-quality second opinion. Capture the local evidence first; that keeps a cloud call short, auditable, and cheap.
