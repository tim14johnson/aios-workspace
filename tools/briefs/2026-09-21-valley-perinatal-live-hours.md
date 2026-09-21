# Brief: Valley Perinatal — Live Toggl Hours

Replace the placeholder zeros in `ValleyPerinatalView` with real data fetched from the
Toggl Track v9 API and computed through the existing pure AiOSCore calculators.

---

## What already exists — do not redefine

**AiOSCore types (import AiOSCore):**
- `TogglTimeEntry` — in `AiOSCore/Sources/AiOSCore/TogglModels.swift`
  - `.id: Int`, `.projectID: Int?`, `.description: String?`, `.start: Date`, `.duration: Int`
  - `.isCompleted: Bool` — true when `duration > 0`
- `TogglBillingSync.sync(input: SyncInput) -> SyncResult` — pure, no side effects
  - `SyncInput(financeProjectID:workspaceScope:togglProjectIDs:fetchedEntries:rates:existingTogglEntryIDs:lockedTogglEntryIDs:)`
  - `SyncResult.newEntries: [BillableTimeEntry]`, `.completedEntries: [BillableTimeEntry]`
- `BillableTimeEntry` — `.durationHours: Decimal`, `.invoiceState: InvoiceState`, `.isBillable: Bool`, `.earnedAmount: Decimal?`
- `InvoiceState.unbilled`
- `EffectiveDatedRate(id:ratePerHour:currency:effectiveFrom:effectiveThrough:)` — all public init
- `WeeklyHoursAllocation(weeklyLimitHours:weekStartDay:includeNonBillableHours:alertThresholds:)`
- `WeeklyHoursCalculator.status(for:projectID:entries:allocation:) -> WeeklyHoursStatus`
  - `WeeklyHoursStatus.approvedBillableHours`, `.remainingHours`, `.isOverCap`, `.incompleteEntryCount`
- `FreelanceIncomeCalculator.snapshot(projectID:entries:payments:weeklyAllocation:currentRate:asOf:) -> FreelanceIncomeSnapshot`
  - `FreelanceIncomeSnapshot.earnedUnbilledAmount`, `.totalEarned`
- `FinanceWorkspaceScope` — must check existing cases; use `.personal` if it exists, else first case

**AiOSMyFamily existing view (do NOT rename or restructure):**
- `ValleyPerinatalView` in `AiOSMyFamily/AiOSMyFamily/FinanceFlow.swift` — currently uses
  hardcoded placeholders. Replace ONLY these properties and their usages:
  - `private let weeklyCapHours: Decimal = 20` — keep as a constant default; read from store instead
  - `private let ratePerHour: Decimal = 0` — replace with store-loaded value
  - `@State private var approvedHoursThisWeek: Decimal = 0` — replace with computed value
  - `@State private var unbilledHours: Decimal = 0` — replace with computed value
  - `@State private var showRatePrompt = false` — replace the "Set rate" alert with a real settings sheet

---

## Files to create

### 1. `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalStore.swift`

**Persist BillableTimeEntry as JSONL. Store config in UserDefaults.**

```swift
import Foundation
import AiOSCore

// MARK: - Config (UserDefaults)

struct ValleyPerinatalConfig {
    static let projectID = "valley-perinatal"

    private static func key(_ s: String) -> String { "aios.vp.\(s)" }

    static var togglAPIToken: String {
        get { UserDefaults.standard.string(forKey: key("togglAPIToken")) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key("togglAPIToken")) }
    }

    static var togglProjectIDs: [Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key("togglProjectIDs")),
                  let ids = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
            return ids
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key("togglProjectIDs"))
        }
    }

    static var ratePerHour: Decimal {
        get { Decimal(UserDefaults.standard.double(forKey: key("ratePerHour"))) }
        set { UserDefaults.standard.set(NSDecimalNumber(decimal: newValue).doubleValue, forKey: key("ratePerHour")) }
    }

    static var weeklyCapHours: Decimal {
        get {
            let v = UserDefaults.standard.double(forKey: key("weeklyCapHours"))
            return v > 0 ? Decimal(v) : 20
        }
        set { UserDefaults.standard.set(NSDecimalNumber(decimal: newValue).doubleValue, forKey: key("weeklyCapHours")) }
    }
}

// MARK: - JSONL store for BillableTimeEntry

actor ValleyPerinatalStore {
    static let shared = ValleyPerinatalStore()

    private var entries: [BillableTimeEntry] = []
    private var loaded = false

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AiOS/Finance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("valley-perinatal-entries.jsonl")
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let lines = try? String(contentsOf: storeURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = lines.split(separator: "\n").compactMap {
            try? decoder.decode(BillableTimeEntry.self, from: Data($0.utf8))
        }
    }

    func allEntries() -> [BillableTimeEntry] { entries }

    func existingTogglIDs() -> Set<Int> { Set(entries.map(\.togglEntryID)) }

    func merge(_ newEntries: [BillableTimeEntry]) {
        let newIDs = Set(newEntries.map(\.togglEntryID))
        entries.removeAll { newIDs.contains($0.togglEntryID) }
        entries.append(contentsOf: newEntries)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = entries.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        try? lines.data(using: .utf8)?.write(to: storeURL)
    }
}
```

---

### 2. `AiOSMyFamily/AiOSMyFamily/TogglFetcher.swift`

**Fetch time entries from Toggl Track API v9. No dependencies beyond Foundation + AiOSCore.**

```swift
import Foundation
import AiOSCore

enum TogglFetchError: Error {
    case noToken
    case httpError(Int)
    case decodeFailed
}

enum TogglFetcher {

    /// Fetch completed time entries for the last `days` calendar days.
    static func fetchEntries(apiToken: String, days: Int = 90) async throws -> [TogglTimeEntry] {
        guard !apiToken.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TogglFetchError.noToken
        }
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now) ?? now

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let start = fmt.string(from: startDate)
        let end   = fmt.string(from: now)

        var components = URLComponents(string: "https://api.track.toggl.com/api/v9/me/time_entries")!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date",   value: end),
        ]
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 30

        // Toggl Basic auth: username = "api_token", password = the token
        let creds = "api_token:\(apiToken)"
        let b64 = Data(creds.utf8).base64EncodedString()
        req.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TogglFetchError.httpError(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([TogglTimeEntry].self, from: data) else {
            throw TogglFetchError.decodeFailed
        }
        return entries
    }
}
```

---

### 3. `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalController.swift`

**@Observable controller. Owns fetch + sync + calculation. Used by ValleyPerinatalView.**

```swift
import Foundation
import Observation
import AiOSCore

@MainActor
@Observable
final class ValleyPerinatalController {

    // Published state consumed by the view
    private(set) var weeklyStatus: WeeklyHoursStatus? = nil
    private(set) var incomeSnapshot: FreelanceIncomeSnapshot? = nil
    private(set) var incompleteCount = 0
    private(set) var isSyncing = false
    private(set) var syncError: String? = nil
    private(set) var lastSynced: Date? = nil

    private let store = ValleyPerinatalStore.shared

    func loadLocal() async {
        await store.loadIfNeeded()
        recompute()
    }

    func sync() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        let token = ValleyPerinatalConfig.togglAPIToken
        guard !token.isEmpty else {
            syncError = "Toggl API token not configured — tap Settings."
            return
        }
        guard !ValleyPerinatalConfig.togglProjectIDs.isEmpty else {
            syncError = "No Toggl project IDs configured — tap Settings."
            return
        }

        do {
            let fetched = try await TogglFetcher.fetchEntries(apiToken: token)
            let existing = await store.existingTogglIDs()
            let rate = makeRate()

            let input = TogglBillingSync.SyncInput(
                financeProjectID: ValleyPerinatalConfig.projectID,
                workspaceScope: .personal,
                togglProjectIDs: Set(ValleyPerinatalConfig.togglProjectIDs),
                fetchedEntries: fetched,
                rates: rate.map { [$0] } ?? [],
                existingTogglEntryIDs: existing
            )
            let result = TogglBillingSync.sync(input: input)
            await store.merge(result.newEntries + result.completedEntries)
            lastSynced = Date()
            recompute()
        } catch TogglFetchError.noToken {
            syncError = "Toggl API token not configured."
        } catch TogglFetchError.httpError(let code) {
            syncError = "Toggl returned HTTP \(code). Check token or network."
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func recompute() {
        let entries = (try? await store.allEntries()) ?? []
        // Note: recompute is called from @MainActor context; store.allEntries() is async.
        // Since this is a synchronous helper called inline, compute off already-loaded entries.
        // Use Task to load and recompute:
        Task {
            let all = await store.allEntries()
            let allocation = makeAllocation()
            let status = WeeklyHoursCalculator.status(
                for: Date(),
                projectID: ValleyPerinatalConfig.projectID,
                entries: all,
                allocation: allocation
            )
            let rate = makeRate()
            let income = FreelanceIncomeCalculator.snapshot(
                projectID: ValleyPerinatalConfig.projectID,
                entries: all,
                payments: [],
                weeklyAllocation: allocation,
                currentRate: rate
            )
            weeklyStatus = status
            incomeSnapshot = income
            incompleteCount = status.incompleteEntryCount
        }
    }

    private func makeAllocation() -> WeeklyHoursAllocation {
        WeeklyHoursAllocation(
            weeklyLimitHours: ValleyPerinatalConfig.weeklyCapHours,
            weekStartDay: 2,   // Monday
            includeNonBillableHours: false,
            alertThresholds: [15, 18, 20]
        )
    }

    private func makeRate() -> EffectiveDatedRate? {
        let r = ValleyPerinatalConfig.ratePerHour
        guard r > 0 else { return nil }
        return EffectiveDatedRate(
            ratePerHour: r,
            currency: "USD",
            effectiveFrom: .distantPast
        )
    }
}
```

> NOTE: `recompute()` has a Task-inside-a-function shape — if this causes a compile warning about
> implicit async context, convert the whole function to `async` and await it directly from `loadLocal()`
> and `sync()`. Do not change the pattern if it compiles cleanly.

---

## Modify: `AiOSMyFamily/AiOSMyFamily/FinanceFlow.swift`

**`ValleyPerinatalView` only — no other views in this file.**

### Replace the stored properties block (top of ValleyPerinatalView)

**BEFORE:**
```swift
    private let weeklyCapHours: Decimal = 20
    private let ratePerHour: Decimal = 0
    private let currency = "USD"

    @State private var approvedHoursThisWeek: Decimal = 0
    @State private var unbilledHours: Decimal = 0
    @State private var showRatePrompt = false
```

**AFTER:**
```swift
    @State private var controller = ValleyPerinatalController()
    @State private var showSettings = false

    private var weeklyCapHours: Decimal { controller.weeklyStatus?.allocation.weeklyLimitHours ?? 20 }
    private var approvedHoursThisWeek: Decimal { controller.weeklyStatus?.approvedBillableHours ?? 0 }
    private var ratePerHour: Decimal { ValleyPerinatalConfig.ratePerHour }
    private var unbilledHours: Decimal {
        controller.incomeSnapshot.map { $0.earnedUnbilledAmount / max(ratePerHour, 1) } ?? 0
    }
```

### Replace the `.alert("Set hourly rate", ...)` at the bottom of `body`

**BEFORE:**
```swift
        .alert("Set hourly rate", isPresented: $showRatePrompt) {
            Button("OK") {}
        } message: {
            Text("Add your rate to docs/finance-source-inventory.md — it will be seeded into EffectiveDatedRate on next build.")
        }
```

**AFTER:**
```swift
        .sheet(isPresented: $showSettings) {
            ValleyPerinatalSettingsSheet()
        }
        .task { await controller.loadLocal() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await controller.sync() }
                } label: {
                    if controller.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(controller.isSyncing)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Settings") { showSettings = true }
            }
        }
```

### Replace the "Rate not configured" button in the Earnings section

**BEFORE:**
```swift
                        Button("Set rate") { showRatePrompt = true }
                            .font(.caption).buttonStyle(.bordered)
```

**AFTER:**
```swift
                        Button("Set rate") { showSettings = true }
                            .font(.caption).buttonStyle(.bordered)
```

### Add sync-error banner after the existing "invoice pipeline" section, before the info footer Section:

```swift
            if let err = controller.syncError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
```

### Replace the data-not-connected footer Section

**BEFORE:**
```swift
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Data not yet connected", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Hours above are placeholders. Connect Toggl by wiring TogglBillingSync to a live TogglConnector in a future build step.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
```

**AFTER:**
```swift
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if let synced = controller.lastSynced {
                        Text("Last synced \(synced.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Label("Tap Sync to pull from Toggl Track.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.incompleteCount > 0 {
                        Label("\(controller.incompleteCount) entries need descriptions in Toggl", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
```

---

### Add `ValleyPerinatalSettingsSheet` (same file, after `ValleyPerinatalView`)

```swift
struct ValleyPerinatalSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiToken = ValleyPerinatalConfig.togglAPIToken
    @State private var projectIDsText = ValleyPerinatalConfig.togglProjectIDs.map(String.init).joined(separator: ", ")
    @State private var rate = ValleyPerinatalConfig.ratePerHour
    @State private var cap  = ValleyPerinatalConfig.weeklyCapHours

    var body: some View {
        NavigationStack {
            Form {
                Section("Toggl Track") {
                    TextField("API Token", text: $apiToken)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Project IDs (comma-separated)", text: $projectIDsText)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
                Section("Billing") {
                    LabeledContent("Hourly rate (USD)") {
                        TextField("0.00", value: $rate, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper("Weekly cap: \(cap.formatted()) hrs", value: $cap, in: 1...40, step: 1)
                }
                Section {
                    Link("Find your Toggl API token",
                         destination: URL(string: "https://track.toggl.com/profile")!)
                        .font(.caption)
                }
            }
            .navigationTitle("Valley Perinatal Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ValleyPerinatalConfig.togglAPIToken = apiToken.trimmingCharacters(in: .whitespaces)
                        ValleyPerinatalConfig.togglProjectIDs = projectIDsText
                            .split(separator: ",")
                            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        ValleyPerinatalConfig.ratePerHour = rate
                        ValleyPerinatalConfig.weeklyCapHours = cap
                        dismiss()
                    }
                }
            }
        }
    }
}
```

---

## Acceptance criteria

1. Build succeeds with zero new warnings.
2. `ValleyPerinatalView` shows `0.0 hrs` (not zeroed placeholders) from real `WeeklyHoursCalculator` output.
3. Tapping Sync with no token shows the error banner; does not crash.
4. Tapping Settings opens the sheet; saving writes to UserDefaults.
5. The "Earnings" section shows "Rate not configured" when rate = 0; shows real values when configured.
6. No changes to any view outside `ValleyPerinatalView` in `FinanceFlow.swift`.
7. `TogglFetcher`, `ValleyPerinatalStore`, `ValleyPerinatalController` are new files — do NOT inline them into `FinanceFlow.swift`.

---

## Key paths

| File | Action |
|---|---|
| `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalStore.swift` | CREATE |
| `AiOSMyFamily/AiOSMyFamily/TogglFetcher.swift` | CREATE |
| `AiOSMyFamily/AiOSMyFamily/ValleyPerinatalController.swift` | CREATE |
| `AiOSMyFamily/AiOSMyFamily/FinanceFlow.swift` | MODIFY — `ValleyPerinatalView` + add `ValleyPerinatalSettingsSheet` |
