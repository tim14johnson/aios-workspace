# Brief: Cover Letter Local-Model Fallback + ComputeWorker Spoke Wiring

Two self-contained fixes. Both compile-clean with no new dependencies.

---

## Fix 1 — LocalModelCoverLetterWriter (Hub only)

### Problem

`TailorResumeSheet` in `AiOSHub/AiOSHub/ContentView.swift` selects its cover letter writer with:

```swift
let coverWriter: CoverLetterWriter = {
    if #available(macOS 26.0, *), aiOn { return FoundationModelsCoverLetterWriter() }
    return TemplateCoverLetterWriter()   // ← generic output when Apple Intelligence is off
}()
```

When Apple Intelligence is unavailable the letter is always the generic template. The Hub
already has Qwen 27B running on port 8080. Use it.

### What already exists (do not duplicate)

- `AiOSCore/Sources/AiOSCore/CoverLetterWriter.swift` — `CoverLetterWriter` protocol,
  `CoverLetterInput`, `CoverLetter`, `CoverLetterGroundingGate`, `FallbackCoverLetterWriter`,
  `TemplateCoverLetterWriter`, `FoundationModelsCoverLetterWriter`.
- `CoverLetterGroundingGate` is already applied inside `FoundationModelsCoverLetterWriter.write()`.
- `CoverLetterInput` already carries `correlationMap` (themed evidence) and `voiceSamples`.
  Both are populated at the call site — do not touch the call site.

### Create: `AiOSHub/AiOSHub/LocalModelCoverLetterWriter.swift`

```
// Package: AiOSHub app target (not AiOSCore — it imports Foundation + AiOSCore only)
```

Implement `LocalModelCoverLetterWriter: CoverLetterWriter` (a struct, not an actor):

```swift
import Foundation
import AiOSCore

/// Calls the local OpenAI-compatible server (Qwen 27B on :8080) for grounded cover letters
/// when Apple Foundation Models is unavailable.
struct LocalModelCoverLetterWriter: CoverLetterWriter {
    let baseURL: URL   // e.g. URL(string: "http://127.0.0.1:8080")!
    var timeoutSeconds: Double = 120

    func write(_ input: CoverLetterInput) async throws -> CoverLetter {
        let prompt = Self.prompt(for: input)
        let body: [String: Any] = [
            "model": "qwen",
            "messages": [
                ["role": "system", "content": "You are a professional cover letter writer. Write in first person as the candidate. Only use facts explicitly provided."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 600,
            "temperature": 0.4
        ]
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String else {
            throw CoverLetterWriterError.noContent
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter = CoverLetter(body: trimmed, model: "Qwen (local)")
        try CoverLetterGroundingGate.checkGrounded(letter, against: input)
        return letter
    }

    private static func prompt(for input: CoverLetterInput) -> String {
        if let map = input.correlationMap {
            let voice = input.voiceSamples.isEmpty
                ? "(none yet — write with direct, confident professional tone)"
                : input.voiceSamples.joined(separator: "\n---\n")
            return """
            Write a concise cover letter (3 short paragraphs, ~200 words) for this candidate.

            STRICT RULE: ONLY reference facts in the EVIDENCE below. Never invent employers, titles, metrics, or dates.
            VOICE: Match the tone of these approved letters from the candidate:
            \(voice)

            JD THEME MAP (one body paragraph per covered theme):
            \(map.promptBrief())

            CANDIDATE: \(input.candidateName)
            ROLE: \(input.role) at \(input.company)
            End with: Sincerely,\n\(input.candidateName)
            """
        }
        let skills = input.skills.prefix(20).joined(separator: ", ")
        let exp = input.experienceHighlights.prefix(5).joined(separator: "; ")
        return """
        Write a concise cover letter (3 short paragraphs, ~200 words).
        STRICT RULE: Only use the candidate facts provided. Do NOT invent employers, titles, or metrics.
        Candidate: \(input.candidateName)
        Skills: \(skills.isEmpty ? "(none provided)" : skills)
        Experience: \(exp.isEmpty ? "(none provided)" : exp)
        Job: \(input.role) at \(input.company)
        JD: \(String(input.jobDescription.prefix(2000)))
        End with: Sincerely,\n\(input.candidateName)
        """
    }
}

enum CoverLetterWriterError: Error { case noContent }
```

> NOTE: `CoverLetterGroundingGate.checkGrounded(_:against:)` is `static` and `throws` — call it directly.

### Modify: `AiOSHub/AiOSHub/ContentView.swift` (one block only)

Find this block (around line 2684):

```swift
        let coverWriter: CoverLetterWriter = {
            if #available(macOS 26.0, *), aiOn { return FoundationModelsCoverLetterWriter() }
            return TemplateCoverLetterWriter()
        }()
```

Replace with:

```swift
        let coverWriter: CoverLetterWriter = {
            if #available(macOS 26.0, *), aiOn { return FoundationModelsCoverLetterWriter() }
            // Apple Intelligence unavailable — try local Qwen 27B (port 8080) grounded, then template.
            return FallbackCoverLetterWriter(
                primary: LocalModelCoverLetterWriter(baseURL: URL(string: "http://127.0.0.1:8080")!),
                secondary: TemplateCoverLetterWriter()
            )
        }()
```

Do NOT change anything else in this function.

---

## Fix 2 — ComputeWorker in spoke app targets

### Problem

`ComputeWorker` (in `AiOSCore/Sources/AiOSCore/ComputeWorker.swift`) is fully built but never
started in any spoke app target. Both `AiOSMyFamily` and `AiOSBusiness` have a `SpokeController`
that already has `hubClient() -> PairedHubClient?` and a `pairing: PairingState` property.
Wire `ComputeWorker` into both.

### Existing types (do not redefine)

```
AiOSCore: ComputeWorker (actor), IdleDetector, AlwaysIdleDetector, PairedHubClient
```

`ComputeWorker.init(client: PairedHubClient, deviceID: String, idle: IdleDetector, pollInterval: Duration)`
`ComputeWorker.start()` — async, idempotent
`ComputeWorker.stop()` — sync

### Modify: `AiOSMyFamily/AiOSMyFamily/SpokeController.swift`

`SpokeController` is `@MainActor @Observable final class`. Add three changes:

**1. Add a stored property** (near the other private stored properties, after `private var binding`):

```swift
    private var computeWorker: ComputeWorker?
```

**2. Add a private helper** (before the closing `}` of the class):

```swift
    private func startComputeWorkerIfNeeded() {
        guard computeWorker == nil, let client = hubClient() else { return }
        let worker = ComputeWorker(client: client, deviceID: identity?.name ?? tenant.rawValue)
        computeWorker = worker
        Task { await worker.start() }
    }
```

**3. Wire it in three places:**

a) In `init(tenant:connectors:)`, after the line `self.pairing = binding == nil ? .unpaired : .paired`:

```swift
        if pairing == .paired { startComputeWorkerIfNeeded() }
```

b) In `pair()`, immediately after the line `pairing = .paired` (inside the `.approved` case):

```swift
                    startComputeWorkerIfNeeded()
```

c) In `unpair()`, after `pairing = .unpaired`:

```swift
        computeWorker?.stop()
        computeWorker = nil
```

### Modify: `AiOSBusiness/AiOSBusiness/SpokeController.swift`

Apply the **identical** three changes described above. The two `SpokeController` files are
structurally identical — line numbers may differ slightly but the hook points are the same.

---

## Acceptance criteria

1. Build succeeds with zero new warnings.
2. `LocalModelCoverLetterWriter` compiles — it only uses `Foundation` + `AiOSCore` (no new frameworks).
3. Both `SpokeController` files have `computeWorker` property and `startComputeWorkerIfNeeded()`.
4. No other files are touched.

---

## Key paths

| File | Action |
|---|---|
| `AiOSHub/AiOSHub/LocalModelCoverLetterWriter.swift` | CREATE |
| `AiOSHub/AiOSHub/ContentView.swift` | MODIFY (one block, ~3 lines) |
| `AiOSMyFamily/AiOSMyFamily/SpokeController.swift` | MODIFY (add property + helper + 3 wire points) |
| `AiOSBusiness/AiOSBusiness/SpokeController.swift` | MODIFY (same as above) |
