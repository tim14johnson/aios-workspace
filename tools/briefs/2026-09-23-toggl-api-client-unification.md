# CLI Brief — Unify the duplicated Toggl HTTP client (and resolve a real auth-order discrepancy)

**Filed:** 2026-09-23
**Companion doc:** `docs/architecture/2026-09-22-back-to-basics-review.md`, Phase 2/connector-library section.
**Priority context:** A research pass tonight found `TogglConnector` (AiOSHub, Job Seeker's "time spent job searching" feature) and `TogglFetcher` (AiOSMyFamily, Valley Perinatal billing) independently hand-roll the identical Toggl v9 Basic-auth HTTP GET — the same caliber of evidenced duplication as tonight's grounding-gate unification. This is the smaller, well-scoped prerequisite flagged before any `SpokeConnector` wrapping of Toggl is even worth attempting (confirmed separately: `TogglBillingSync`'s actual sync logic is a pure function with no network of its own, and doesn't map cleanly onto `SpokeConnector`'s `ConnectorOutput` shape — not part of this brief, don't touch it).

**A real discrepancy found while scoping, not yet resolved — resolve it as part of this unification, don't just pick one arbitrarily:** `TogglConnector.swift`'s own doc comment says Toggl v9 Basic auth uses "the API token as username and the literal 'api_token' password." `TogglFetcher.swift` does the exact opposite: `let creds = "api_token:\(apiToken)"` (i.e. username = the literal `"api_token"`, password = the token). These cannot both be the documented-correct form. Check Toggl's actual API v9 documentation (or any other authoritative signal in this codebase, e.g. comments/memory files referencing verified-live behavior) before picking which is correct — both may currently "work" only because Toggl's server happens to accept either ordering, which would mean neither implementation was ever actually verified against the spec. Report what you find either way.

**Explicit non-goals:**
- Do NOT wrap Toggl as a `SpokeConnector`/wire it into `ConnectorSlot`. Confirmed a poor direct fit for a separate reason (structured billing sync, not sensor-shaped) — that's not this brief.
- Do NOT touch `TogglBillingSync.swift` (`AiOSCore/Sources/AiOSCore/Finance/`) — it has no network of its own today; leave it untouched.
- Do NOT touch `TogglActivity`'s decoding/summarization logic (`TogglActivity.decoder()`, `.projects(named:in:)`, `.entries(_:inProjects:)`, `.summary(of:)`, `.secondsPerApplication(...)`) — that's already shared between both callers (both already call the same `TogglActivity.decoder()`); only the raw HTTP/auth mechanics are duplicated. Don't refactor what isn't broken.
- Do NOT change `TogglConnector`'s public `@MainActor @Observable` UI-facing API (`apiToken`, `projectName`, `pull(daysBack:applications:)`, `entries`, `summary`, `perApplicationSeconds`, `matchedEntries(company:)`) or `TogglFetcher.fetchEntries(apiToken:days:)`'s public signature — both keep their exact existing call-site behavior; only their *internal* HTTP mechanics delegate to the new shared client.

---

## What already exists — read before writing anything

- `AiOSHub/AiOSHub/TogglConnector.swift` — full file, already read tonight. `get(_:token:query:)` (private, near the bottom) builds the request, sets the Basic-auth header, calls `URLSession.shared.data(for:)` directly — no injection seam.
- `AiOSMyFamily/AiOSMyFamily/TogglFetcher.swift` — full file, already read tonight in full (it's short). `fetchEntries(apiToken:days:)` (the sole static method) does the same thing independently: builds the URL/query, builds the (reversed) Basic-auth header, calls `URLSession.shared.data(for:)` directly.
- `AiOSCore/Sources/AiOSCore/RemoteAnalyticsEngine.swift`'s `Transport` typealias and `AiOSCore/Sources/AiOSCore/AiOSLanguageModel.swift`'s `OpenAICompatibleLanguageModel` — this codebase's now-established idiom (used twice already tonight) for extracting a raw HTTP primitive with an injectable transport, defaulting to real `URLSession` when unconfigured. Mirror this exact shape a third time — don't invent a different pattern.
- `TogglActivity`, `TogglTimeEntry`, `TogglProject` (find via grep in `AiOSCore/Sources/AiOSCore/`) — the shared decode/domain types both callers already use identically. Read enough to confirm the new client should return raw `Data` (letting each caller keep decoding via `TogglActivity.decoder()` exactly as today) rather than pre-decoding — keep the extraction minimal, matching only what's actually duplicated.

---

## What to build

### 1. `TogglAPIClient` — the real, shared, injectable HTTP primitive

New file, `AiOSCore/Sources/AiOSCore/TogglAPIClient.swift`:
- `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)` (or reuse an existing one if one's already public and suitable — check first).
- `public init(apiToken: String, transport: Transport? = nil)`.
- `public func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data` — builds `https://api.track.toggl.com/api/v9/\(path)`, the query items, the Basic-auth header (using whichever ordering you've confirmed correct per the discrepancy above), a real timeout, calls the transport (or real `URLSession` if `nil`), and throws on non-200 (mirror `TogglFetchError`'s existing cases, or reuse them if they're a good fit and accessible — check accessibility/location first).

### 2. Both callers delegate

`TogglConnector.get(_:token:query:)` and `TogglFetcher.fetchEntries(apiToken:days:)` construct a `TogglAPIClient` internally and call `.get(...)`, then decode exactly as they do today via `TogglActivity.decoder()`. Delete the now-dead duplicate HTTP/auth-building code from both — no leftover copies.

---

## Tests

New `AiOSCore/Tests/AiOSCoreTests/TogglAPIClientTests.swift`: using a fake `Transport`, confirm the request URL/path/query is correct, the Basic-auth header is built correctly (assert its exact value against what you've confirmed is the documented-correct form), and a non-200 response throws. Confirm any existing tests for `TogglConnector`/`TogglFetcher` (grep for them) still pass with unchanged intent.

---

## Build verification

```
cd "/Volumes/AiOS Repository/code/AiOSCore" && swift build && swift test
cd "/Volumes/AiOS Repository/code/AiOSHub" && xcodebuild -project AiOSHub.xcodeproj -scheme AiOSHub -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
cd "/Volumes/AiOS Repository/code/AiOSMyFamily" && xcodebuild -project AiOSMyFamily.xcodeproj -scheme AiOSMyFamily -configuration Debug build -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
```
Zero errors, zero new warnings, on all four.

---

## Acceptance criteria

1. `TogglAPIClient` exists, real and injectable, matching the codebase's established `Transport` idiom.
2. Both `TogglConnector` and `TogglFetcher` delegate to it — no duplicate HTTP/auth code left in either.
3. The username/password ordering discrepancy is investigated and resolved (report what you found, which was correct, and why).
4. Neither caller's public API/behavior changed for its own consumers.
5. All four build/test combinations green.

---

## Commit

```
feat(library): unify the duplicated Toggl HTTP client into TogglAPIClient, resolve the Basic-auth ordering discrepancy

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
```

Repos touched: AiOSCore, AiOSHub, AiOSMyFamily.

## Key paths

| File | Repo | Action |
|---|---|---|
| `AiOSCore/Sources/AiOSCore/TogglAPIClient.swift` | AiOSCore | CREATE |
| `AiOSCore/Tests/AiOSCoreTests/TogglAPIClientTests.swift` | AiOSCore | CREATE |
| `AiOSHub/AiOSHub/TogglConnector.swift` | AiOSHub | MODIFY — delegate to `TogglAPIClient` |
| `AiOSMyFamily/AiOSMyFamily/TogglFetcher.swift` | AiOSMyFamily | MODIFY — delegate to `TogglAPIClient` |
