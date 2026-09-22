# CLI Brief — Library, second slice: extract the real `AiOSLanguageModel` primitive

**Filed:** 2026-09-22
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 2 section.
**Priority context:** Tim's stated order is Index (done) → Library (in progress: connector-checkout landed as slice 1, commits AiOSCore `f5330fa`/AiOSBusiness `0955b20`) → dual-engine unification (deprioritized). This is Library slice 2 — the model third of "models, tools, and connectors." A separate scoping pass for "tools" (the third leg) follows this slice, not combined with it.

**Goal:** No `ModelProfile`/language-model abstraction exists anywhere in the product code today. But the raw primitive it needs already exists, informally, buried inside `RemoteAnalyticsEngine` (`AiOSCore/Sources/AiOSCore/RemoteAnalyticsEngine.swift`) — its `makeChatRequest`/`transport`/`messageContent` machinery IS an OpenAI-compatible chat-completion call, it's just private, undifferentiated implementation detail of one analytics engine rather than a real, reusable, named thing. `AiOSOrchestrator`'s `LanguageModel` protocol (`AiOSOrchestrator/Sources/OrchestratorKit/LanguageModel.swift` — a dev-tool-only type, not itself reused) already names the right shape and its own doc comment says it mirrors "the product's ModelProfile" — i.e. a product-side equivalent was anticipated but never built. Pull the real primitive out, prove it with one genuine conformer, without changing any observable behavor. Exactly the "extract a real, general thing from code that already does the job informally" move the last several Index/Library slices have made.

**Explicit non-goals — read before writing anything:**
- Do NOT build a "checkout" / model-selection registry (deciding *which* model handles a given request). That needs at least two real conformers to mean anything, and this slice only proves one. It's the deliberately separate next slice.
- Do NOT touch `FoundationModelsFFAReasoner`/`FFAReasoner` (`AiOSCore/Sources/AiOSCore/Finance/FoundationModelsFFAReasoner.swift`) or its `RawReasoner`'s `LanguageModelSession.respond(to:)` call. It's a genuinely different shape (Apple's on-device API takes one combined prompt, not a system/user split; it's `@available(macOS 26.0, *)`-gated; it's live in FFA today) — wrapping it as a second `AiOSLanguageModel` conformer is real, valuable follow-on work, but combining it with this extraction raises regression risk on a live feature for no proven benefit yet. Leave it untouched.
- Do NOT change `RemoteBrainConfig`'s public fields (`endpoint`, `model`, `timeoutSeconds`, `maxInsights`, `maxActions`, `disableThinking`, `baselineContext`) or `BrainService.swift`'s UI/behavior. This must be invisible to every existing caller — same bar as the Finance→ObjectStore migration ("a pure persistence-layer swap, invisible to the user"), just applied to a compute call instead of storage.
- Do NOT touch `TandemAnalyticsEngine`, `AnalyticsEngine` protocol, `HubController`'s engine wiring, or any Job Seeker UI.
- Do NOT touch `ConnectorSlot`/`BlueprintConfiguration` or anything from the just-landed connector slice.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/RemoteAnalyticsEngine.swift` — the full file, already read in full tonight while scoping. Key structure: `RemoteBrainConfig` (analytics-specific config: model, timeouts, insight/action caps, `disableThinking`, `baselineContext`), `RemoteAnalyticsEngine` (conforms to `AnalyticsEngine`) with `Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)` (already an injectable-for-tests typealias — mirror this exact idiom, don't invent a new one), `makeRequest(signals:)` (analytics-specific prompt building — stays put), `makeChatRequest(messages:maxTokens:)` (the generic HTTP mechanics — this is the extraction target), `warmUp()` (calls `makeChatRequest` with a 1-token probe), `messageContent(from:)` (extracts `choices[0].message.content` from an OpenAI-style response — also extraction target). `analyze()`, `decodeBrainOutput`/`grounded`/the whole grounding gate stay exactly where they are — they're analytics-specific, not part of the raw model-call primitive.
- `AiOSOrchestrator/Sources/OrchestratorKit/LanguageModel.swift` — full file, already read tonight. The shape to mirror in AiOSCore: `protocol LanguageModel: Sendable { var label: String { get }; func complete(system: String, user: String) async throws -> String }`. Note this protocol takes no `maxTokens` parameter — but `RemoteAnalyticsEngine` genuinely needs a variable token budget (1 for `warmUp()`'s probe, 4096 for the real analyze pass) — so the new AiOSCore protocol should NOT be a byte-for-byte copy; add a `maxTokens: Int` parameter to `complete(...)`, this is a real, grounded difference from the dev-tool's version, not an arbitrary deviation. Document why in a doc comment.
- `AiOSHub/AiOSHub/BrainService.swift` — full file, already read tonight. Not touched by this slice's non-goals, but read it to see exactly how `RemoteBrainConfig`/`RemoteAnalyticsEngine` get constructed and called from a real UI, so you can verify by inspection (not just by running tests) that nothing about its behavior changes.
- `AiOSCore/Sources/AiOSCore/TandemAnalyticsEngine.swift` — full file, already read tonight. Constructs its own `RemoteAnalyticsEngine(config: augmented)` internally (line ~51) — another real call site that must keep working unchanged.
- Existing tests: find and read whatever test file currently covers `RemoteAnalyticsEngine` (grep `RemoteAnalyticsEngineTests` or similar under `AiOSCore/Tests/AiOSCoreTests/`) — these are your regression baseline. They must all still pass, unmodified in intent (you may need to adjust internals if you change what's `private` vs not, but the *behavior* they assert must not change).

---

## What to build

### 1. `AiOSLanguageModel` protocol — the real, named primitive

New file, `AiOSCore/Sources/AiOSCore/AiOSLanguageModel.swift`:

```swift
public protocol AiOSLanguageModel: Sendable {
    var modelID: String { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}
```//(exact names/shape are your call within reason — `modelID` vs `label`, error type, etc. — but keep it minimal: this slice is proving the primitive is real and useful, not designing its final complete metadata surface. No capability tags, no cost/latency hints, no `ModelDescriptor` wrapper type yet — that's checkout-slice territory, not this one.)

### 2. `OpenAICompatibleLanguageModel` — the real conformer, extracted from `RemoteAnalyticsEngine`

New type (same file or a new `OpenAICompatibleLanguageModel.swift`, your call) implementing `AiOSLanguageModel` by wrapping exactly the HTTP mechanics currently living in `RemoteAnalyticsEngine.makeChatRequest`/`transport`/`messageContent`: takes an `endpoint: URL`, `model: String`, `timeoutSeconds: TimeInterval`, and an injectable `Transport` (reuse `RemoteAnalyticsEngine.Transport`'s exact typealias shape — consider whether it should move to live on the new type instead, with `RemoteAnalyticsEngine` referencing it from there, your call, but there must be exactly one definition, not two copies). `complete(system:user:maxTokens:)` builds the `["role":"system",...]`/`["role":"user",...]` message array, POSTs it via the same JSON body shape `makeChatRequest` builds today, and returns the extracted `messageContent(from:)` string — throwing on non-200 status or unparseable response (reuse `AnalyticsError` cases or add what's genuinely missing, your call).

### 3. `RemoteAnalyticsEngine` — delegate instead of duplicating

`RemoteAnalyticsEngine` constructs an `OpenAICompatibleLanguageModel` internally (from its own `config`/injected `transport`) and calls `.complete(system:user:maxTokens:)` for both the real `analyze()` path (replacing `makeRequest`+`transport(request)`+`messageContent(from:)`) and `warmUp()`'s 1-token probe (replacing its own `makeChatRequest`+`transport` call). `RemoteAnalyticsEngine.makeRequest` should now just build the system/user *strings* (the analytics-specific prompt content — unchanged) and hand them to the new model's `complete(...)`, rather than building a `URLRequest` itself. Delete `makeChatRequest`/`messageContent` from `RemoteAnalyticsEngine` once nothing calls them directly — don't leave dead duplicate code behind.

**Critical constraint, same as the Finance/ObjectStore migration's own bar:** the exact same requests must be sent (same JSON body shape, same headers, same timeout, same URL path) and the exact same responses parsed, so every existing test (grounding gate, `warmUp()`'s ready/rejected/unreachable distinction, `analyze()`'s error handling) keeps passing unmodified in *intent*. If a test needs to change because internals moved, the *assertion* it makes about behavior must not change.

---

## Tests

- New tests for `OpenAICompatibleLanguageModel` in isolation (a new `AiOSLanguageModelTests.swift` or similar): a fake `Transport` returns a canned OpenAI-style response, `complete(...)` returns the right extracted string; a non-200 response throws; an unparseable response throws.
- Confirm every existing `RemoteAnalyticsEngine`-related test (find the real file name via grep, per the "what already exists" section) still passes, asserting the same behavior as before — read them before and after your change to confirm intent didn't shift, not just that they're green.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings. `AiOSBusiness`/`AiOSMyFamily` don't consume `RemoteAnalyticsEngine` directly (confirm this by grep before skipping their build — if either does reference it, add their build verification too, don't assume). Manually verify by reading the diff that `BrainService.swift` and `TandemAnalyticsEngine.swift` are byte-for-byte unchanged — this must be invisible to both.

---

## Acceptance criteria

1. A real, named `AiOSLanguageModel` protocol exists in AiOSCore, with one genuine conformer (`OpenAICompatibleLanguageModel`) extracted from `RemoteAnalyticsEngine`'s previously-undifferentiated HTTP mechanics.
2. `RemoteAnalyticsEngine` delegates to it rather than duplicating the HTTP/parsing logic — no dead duplicate code left behind.
3. `BrainService.swift`/`TandemAnalyticsEngine.swift` are unchanged — confirmed by diff, not just by claim.
4. Every existing `RemoteAnalyticsEngine` test still passes, asserting the same behavior as before.
5. New tests prove `OpenAICompatibleLanguageModel` works correctly in isolation.
6. AiOSCore build+test green, AiOSHub build green (plus any other repo confirmed via grep to consume `RemoteAnalyticsEngine` directly).

---

## Commit

```
feat(library): extract the real AiOSLanguageModel primitive from RemoteAnalyticsEngine

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore only, expected (confirm no other repo needs changes via grep before assuming).

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/AiOSLanguageModel.swift` | AiOSCore | CREATE — protocol + `OpenAICompatibleLanguageModel` (or split into two files, your call) |
| `AiOSCore/Sources/AiOSCore/RemoteAnalyticsEngine.swift` | AiOSCore | MODIFY — delegate to the new type, delete now-dead duplicate code |
| `AiOSCore/Tests/AiOSCoreTests/AiOSLanguageModelTests.swift` | AiOSCore | CREATE |
| Existing `RemoteAnalyticsEngine` test file (find via grep) | AiOSCore | MODIFY only if internals force it — behavior assertions must not change |
