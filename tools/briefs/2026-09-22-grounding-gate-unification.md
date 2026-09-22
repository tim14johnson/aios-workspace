# CLI Brief — Library, third leg: unify the duplicated grounding-gate check ("Tools," scoped honestly)

**Filed:** 2026-09-22
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 2 section.
**Priority context:** Tim's stated order is Index (done) → Library (connector-checkout landed, model-primitive extraction in flight) → dual-engine unification (deprioritized). This scopes the third leg — "tools" — after a dedicated research pass tonight.

**Read this before assuming "Tools" means what you'd guess it means.** A research pass tonight checked every candidate "tool" concept in the codebase (content extractors, parsers, writers, classifiers, gates) looking for the same thing that made Connectors and Models real, cheap first slices: a dormant-but-real primitive, or a real thing buried informally inside working code. **It found neither, for "tools" in general.** `EmailListingExtractor`, `JDThemeExtractor`, `ResumeParser`, `SystemHealthAnalyzer`, `SchemaClassifier` — at least 8 genuinely heterogeneous shapes, most with no protocol at all, the two that do exist (`CoverLetterWriter`, `SchemaClassifier`) don't overlap with each other. Forcing one "Tool" abstraction over all of that right now would be **invented, not extracted** — exactly the mistake the dual-engine finding already flagged ("n=1 each side, premature"). Don't do that here.

**What IS real and provable:** `CoverLetterGroundingGate` (`AiOSCore/Sources/AiOSCore/CoverLetterWriter.swift`, wraps `CoverLetterWriter`) and `FFAGroundingGate` (`AiOSCore/Sources/AiOSCore/Finance/FoundationModelsFFAReasoner.swift`, wraps `FFAReasoner`) are two independent, hand-built implementations of the identical idea — reject AI-generated output that cites a fact not present in the real structured input — built weeks apart, sharing zero code. This is genuine, narrow, well-evidenced duplication (n=2, not n=1), the same caliber of evidence that justified the connector-checkout and model-extraction slices. **This brief unifies only this,** and explicitly does not attempt anything broader.

**Explicit non-goals — read before writing anything:**
- Do NOT build a general `Tool`/`ToolDescriptor` protocol, registry, or checkout mechanism. Not evidenced, not in scope, not this slice.
- Do NOT touch `EmailListingExtractor`, `JDThemeExtractor`, `ResumeParser`, `SystemHealthAnalyzer`, `SchemaClassifier`, or any other extractor/parser/classifier. Confirmed independently-shaped, no shared abstraction to extract.
- Do NOT change `CoverLetterWriter`'s or `FFAReasoner`'s own protocols, or anything about how `CoverLetterGroundingGate`/`FFAGroundingGate` wrap and decorate their respective inner writer/reasoner. They stay separately conforming to their own domain protocols — that structure is correct and load-bearing (each is a real decorator over a real, different wrapped type). Only the *duplicated internal scanning logic* is the extraction target.
- Do NOT change either gate's actual grounding *rules* (entity-name matching for cover letters, numeric-tolerance matching for FFA) — those are genuinely domain-specific and correct as-is. Extract the shared *scanning control flow* (regex-match, filter exemptions, check against an allowed set, throw with a message on failure), not the domain-specific matching logic itself.
- This brief must NOT run concurrently with any other agent modifying AiOSCore — confirm via `ListAgents`/`git status` that no other agent has uncommitted AiOSCore changes before starting, and again immediately before committing. A concurrent-agent git-index collision on this exact repo happened earlier tonight; don't repeat it.

---

## What already exists — read before writing anything

- `AiOSCore/Sources/AiOSCore/CoverLetterWriter.swift` — full file. `protocol CoverLetterWriter: Sendable { func write(_ input: CoverLetterInput) async throws -> CoverLetter }` (line 47). `CoverLetterGroundingGate` (line 184): wraps `inner: any CoverLetterWriter`, calls it, then `checkGrounded(letter:against:)` — extracts title-case name-like sequences via `NSRegularExpression(pattern: #"\b([A-Z][a-z]+ ){1,3}[A-Z][a-z]+\b"#)`, builds an `approvedNames: Set<String>` from `input.experienceHighlights`/`company`/`candidateName`, exempts a fixed `knownPhrases` set, and throws if any matched entity's words aren't found (via `.contains { approvedNames.contains { $0.contains(word) } }`) in the approved set.
- `AiOSCore/Sources/AiOSCore/Finance/FoundationModelsFFAReasoner.swift` — full file, already read tonight. `protocol FFAReasoner: Sendable { func reason(weights:feedCosts:budget:) async throws -> [FFASuggestion] }`. `FFAGroundingGate` (line 233): wraps `inner: any FFAReasoner`, calls it, then `checkGrounded(suggestions:weights:feedCosts:budget:)` — extracts numeric tokens via `NSRegularExpression(pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"#)`, builds an `allowed: Set<Double>` from the real weights/feed-costs/budget figures, exempts bare small integers (magnitude < 10, no decimal point), and throws if any matched number isn't within `tolerance = 0.02` of an allowed value.
- Read the two `checkGrounded` implementations side by side before writing anything — the shared shape is: **regex-scan text for candidate tokens → drop exempted tokens → for each remaining token, check membership against an allowed set (exact/fuzzy per domain) → throw with a descriptive message on the first ungrounded one.** That control-flow loop, generic over the token type (`String` for names, `Double` for numbers) and the membership test (a closure), is the extraction target — not a shared "GroundingGate protocol" over `CoverLetterWriter`/`FFAReasoner` (those stay separate; only the scanning helper is generic).

---

## What to build

### A single generic scanning helper, used by both gates

New file, `AiOSCore/Sources/AiOSCore/GroundingScan.swift` (or similar — your call on the name, but keep it small and clearly-named for what it does):

```swift
public enum GroundingScan {
    /// Scans `text` for tokens matching `pattern`, drops any exempt per `isExempt`, and throws
    /// `error(for:)` on the first token that fails `isAllowed`. Returns normally if every
    /// non-exempt token is allowed.
    public static func verify(
        text: String,
        pattern: NSRegularExpression,
        isExempt: (String) -> Bool,
        isAllowed: (String) -> Bool,
        error: (String) -> Error
    ) throws {
        // regex-match, filter, check, throw — the shared loop currently duplicated in both gates
    }
}
```

(Exact signature is your call — e.g. whether `isAllowed` takes the raw matched substring and does its own parsing/comparison internally, vs. this helper stays purely string-token-generic and each gate's closure handles its own `Double` parsing — your judgment, but the goal is ONE shared loop, with each gate supplying only its own pattern + exemption rule + allowed-check + error, not two copies of "iterate regex matches, check exemption, check allowed, throw.")

Rewrite `CoverLetterGroundingGate.checkGrounded` and `FFAGroundingGate.checkGrounded` to call this shared helper, supplying their own regex pattern, exemption closure, allowed-check closure (each still does its own domain-specific parsing/comparison — `FFAGroundingGate`'s numeric-tolerance logic and `CoverLetterGroundingGate`'s name-membership logic stay exactly as they are today, just invoked from inside the shared loop instead of duplicating the loop itself), and error constructor (`AnalyticsError.invalidSignal(...)` for FFA — check what `CoverLetterGroundingGate` throws today, likely a different error type; the shared helper's `error` closure lets each gate keep throwing its own real error type, don't force them to unify on one error type if they don't already share one).

**Critical constraint:** every existing behavior of both gates — which specific strings get flagged, which get exempted, the exact thrown error's type/message — must be identical before and after. This is a pure control-flow extraction, not a behavior change, same bar as every other slice tonight.

---

## Tests

- `AiOSCore/Tests/AiOSCoreTests/GroundingScanTests.swift` (new) — direct tests of the shared helper in isolation: a token that fails `isAllowed` throws; an exempted token is skipped even if it would otherwise fail; multiple candidate tokens, only the first ungrounded one's error is thrown (confirm this matches both gates' existing "first failure wins" behavior, or note if either gate actually collects all failures — check the real code, don't assume).
- Whatever existing test files cover `CoverLetterGroundingGate`/`FFAGroundingGate` today (grep for them) — read before and after to confirm the same behaviors are asserted, not just that they're green.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
```
Zero errors, zero new warnings, all existing tests green with unchanged intent. Grep for any other repo (`AiOSHub`, `AiOSBusiness`, `AiOSMyFamily`) directly referencing `CoverLetterGroundingGate`/`FFAGroundingGate` — if any exist, confirm their build is unaffected too (expected: none, since these are internal AiOSCore decorators consumed only through the `CoverLetterWriter`/`FFAReasoner` protocol seam, not directly).

---

## Acceptance criteria

1. One real, shared `GroundingScan` helper exists, used by both `CoverLetterGroundingGate` and `FFAGroundingGate`.
2. Neither gate's actual grounding behavior changed — same tokens flagged, same exemptions, same errors, confirmed by reading tests before/after, not just running them green.
3. No broader "Tool" abstraction was invented — confirm the diff touches only `CoverLetterWriter.swift`, `FoundationModelsFFAReasoner.swift`, and the new `GroundingScan.swift`.
4. AiOSCore build+test green.

---

## Commit

```
feat(library): unify the duplicated grounding-gate scan (CoverLetterGroundingGate/FFAGroundingGate) into one shared helper

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore only.

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/GroundingScan.swift` | AiOSCore | CREATE |
| `AiOSCore/Sources/AiOSCore/CoverLetterWriter.swift` | AiOSCore | MODIFY — `CoverLetterGroundingGate.checkGrounded` delegates to the shared helper |
| `AiOSCore/Sources/AiOSCore/Finance/FoundationModelsFFAReasoner.swift` | AiOSCore | MODIFY — `FFAGroundingGate.checkGrounded` delegates to the shared helper |
| `AiOSCore/Tests/AiOSCoreTests/GroundingScanTests.swift` | AiOSCore | CREATE |
