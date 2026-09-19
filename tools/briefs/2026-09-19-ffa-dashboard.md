# Brief: Universal Dashboard Renderer + FFA First Instance

Build a generic `UniversalDashboardSection` driven by a `DashboardSpec`. FFA is the first
vertical to use it. Every future vertical (job-seeker, health, home-IT) gets a new spec
builder — the renderer is never touched again.

---

## What already exists — do not redefine

**AiOSCore types (import AiOSCore):**
- `CaptureStore` — actor, `CaptureStore.shared`; async: `.weights() -> [CapturedWeight]`,
  `.animalVisits() -> [CapturedAnimalVisit]`, `.receipts() -> [CapturedReceipt]`
- `CapturedWeight` — `.capturedAt: Date`, `.weightLbs: Double`, `.notes: String?`,
  `.displayString: String`
- `CapturedAnimalVisit` — `.visitedAt: Date`, `.feedType: String?`,
  `.healthObservation: String?`, `.animalName: String?`, `.id: UUID`
- `CapturedReceipt` — `.capturedAt: Date`, `.inferredVendor: String?`,
  `.inferredAmount: Decimal?`, `.id: UUID`
- `FFAEntryOutbox.shared` — `.pendingCount() async -> Int`
- `Insight` — `.title: String`, `.detail: String`, `.severity: Double`

**AiOSMyFamily/AiOSMyFamily/FFACaptureSection.swift** contains (all internal visibility):
- `FFAProjectRow` — existing capture-button DisclosureGroup; **keep as-is**
- `FFAVisitSheet`, `FFAReceiptSheet`, `FFAWeightEntrySheet`, `FFAVoiceNoteSheet` — entry sheets
- `FFARecentLogView` — currently `private struct`. **Change to `struct` (remove `private`)**
- `CaptureRow` — already `struct CaptureRow`

**ContentView.swift** (`AiOSMyFamily/AiOSMyFamily/ContentView.swift`):
- `CaptureSection` — calls `FFAProjectRow()` at the bottom; remove that call
- FFA becomes its own `Section` in the main `List`

---

## Changes

### 1. Modify `AiOSMyFamily/AiOSMyFamily/FFACaptureSection.swift`

Change one line only:

```swift
// BEFORE:
private struct FFARecentLogView: View {
// AFTER:
struct FFARecentLogView: View {
```

---

### 2. Modify `AiOSMyFamily/AiOSMyFamily/ContentView.swift`

In `CaptureSection.body`, remove the `FFAProjectRow()` call.

In `ContentView.body`, add after `CaptureSection()`:

```swift
FFADashboardSection()
```

---

### 3. Create `AiOSMyFamily/AiOSMyFamily/UniversalDashboard.swift`

This file contains the generic renderer and the spec types. It has NO FFA-specific logic.
Import `SwiftUI` and `Charts` only.

#### `DashboardSpec`

```swift
struct DashboardSpec {
    let title: String
    let subtitle: String?

    struct ChartSpec {
        let label: String
        let unit: String
        let points: [(date: Date, value: Double)]
        let target: Double?
        let targetLabel: String?
    }

    struct StatSpec: Identifiable {
        let id: UUID
        let label: String
        let value: String   // pre-formatted: "47 days", "$312.50", "12 days away"
        let accent: Bool    // true → accent color (e.g. show is soon)
        init(label: String, value: String, accent: Bool = false) {
            self.id = UUID(); self.label = label; self.value = value; self.accent = accent
        }
    }

    struct ActionSpec: Identifiable {
        let id: UUID
        let label: String
        let icon: String
        let subtitle: String?
        let perform: @MainActor () -> Void
        init(label: String, icon: String, subtitle: String? = nil,
             perform: @escaping @MainActor () -> Void) {
            self.id = UUID(); self.label = label; self.icon = icon
            self.subtitle = subtitle; self.perform = perform
        }
    }

    var chart: ChartSpec?
    var stats: [StatSpec]       // up to 4
    var actions: [ActionSpec]   // up to 5
}
```

#### `UniversalDashboardSection`

A `View` that takes a `spec: DashboardSpec`, a `title: String`, and two optional trailing
closures: `insights: [Insight]` and a `recentLog: AnyView?`.

```swift
struct UniversalDashboardSection: View {
    let title: String
    let spec: DashboardSpec
    var insights: [Insight] = []
    var recentLog: AnyView? = nil

    var body: some View {
        Section(title) {
            // HEADER — subtitle if present
            if let sub = spec.subtitle {
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
            }

            // CHART ZONE — only when >= 2 points
            if let chart = spec.chart, chart.points.count >= 2 {
                chartView(chart)
            } else if spec.chart != nil {
                Text("Log 2+ entries to see trend.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // STATS ZONE
            if !spec.stats.isEmpty {
                statsRow(spec.stats)
            }

            Divider()

            // ACTIONS ZONE
            ForEach(spec.actions) { action in
                Button { action.perform() } label: {
                    CaptureRow(title: action.label, systemImage: action.icon,
                               subtitle: action.subtitle)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // FEED — insights
            if insights.isEmpty {
                Text("No concerns from local data.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(insights.prefix(3), id: \.title) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.title).font(.caption.bold())
                        Text(i.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            // RECENT LOG — injected by the caller
            if let log = recentLog { log }
        }
    }

    // CHART — LineMark + PointMark + optional target RuleMark
    @ViewBuilder
    private func chartView(_ chart: DashboardSpec.ChartSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(chart.label) (\(chart.unit))")
                .font(.caption.bold())
            Chart {
                ForEach(chart.points.suffix(8), id: \.date) { pt in
                    LineMark(
                        x: .value("Date", pt.date),
                        y: .value(chart.label, pt.value)
                    )
                    PointMark(
                        x: .value("Date", pt.date),
                        y: .value(chart.label, pt.value)
                    )
                    .symbolSize(30)
                }
                if let target = chart.target {
                    RuleMark(y: .value(chart.targetLabel ?? "Target", target))
                        .foregroundStyle(.orange)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(chart.targetLabel ?? "Target")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .frame(height: 120)
            .chartXAxis(.hidden)
        }
        .padding(.vertical, 4)
    }

    // STATS — up to 4 in a horizontal LazyVGrid
    @ViewBuilder
    private func statsRow(_ stats: [DashboardSpec.StatSpec]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: min(stats.count, 4)),
                  spacing: 8) {
            ForEach(stats) { stat in
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(stat.accent ? Color.accentColor : .primary)
                    Text(stat.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
```

---

### 4. Create `AiOSMyFamily/AiOSMyFamily/FFADashboardSection.swift`

This file contains ONLY the FFA-specific spec builder + the profile model + the section wrapper.
It knows nothing about chart rendering — it just builds a `DashboardSpec` and hands it to
`UniversalDashboardSection`.

Import `SwiftUI` and `AiOSCore`.

#### `FFAAnimalProfile` (Codable, stored in UserDefaults)

```swift
struct FFAAnimalProfile: Codable {
    var name: String = "Drew's Pig"
    var species: String = "Pig"
    var targetWeightLbs: Double = 280.0
    var showDate: Date? = nil
    var projectStartDate: Date = Date()
}
```

#### `FFAProfileStore`

```swift
@MainActor
final class FFAProfileStore {
    static let shared = FFAProfileStore()
    private let key = "aios.ffa.animalProfile"

    var profile: FFAAnimalProfile {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(FFAAnimalProfile.self, from: data) {
            profile = decoded
        } else {
            profile = FFAAnimalProfile()
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: key)
    }

    /// Builds the DashboardSpec from the current profile + captured data.
    func spec(weights: [CapturedWeight], receipts: [CapturedReceipt],
              onVisit: @escaping @MainActor () -> Void,
              onWeight: @escaping @MainActor () -> Void,
              onReceipt: @escaping @MainActor () -> Void) -> DashboardSpec {
        let sortedWeights = weights.sorted { $0.capturedAt < $1.capturedAt }
        let currentWeight = sortedWeights.last?.weightLbs

        // Chart points
        let points = sortedWeights.map { (date: $0.capturedAt, value: $0.weightLbs) }

        // Stats
        let daysOnFeed = Calendar.current.dateComponents([.day],
            from: profile.projectStartDate, to: Date()).day ?? 0
        let totalSpent = receipts.compactMap { $0.inferredAmount }
            .reduce(Decimal(0), +)
        let spentStr = NumberFormatter.localizedString(
            from: totalSpent as NSDecimalNumber, number: .currency)

        var stats: [DashboardSpec.StatSpec] = [
            .init(label: "Days on feed", value: "\(daysOnFeed)"),
            .init(label: "Total spent",  value: spentStr),
        ]
        if let target = currentWeight.map({ target -> String in
            let diff = profile.targetWeightLbs - $0
            return diff > 0 ? String(format: "%.1f lbs to go", diff) : "At target"
        }) {
            stats.insert(.init(label: "vs target", value: target), at: 1)
        }
        if let show = profile.showDate {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: show).day ?? 0
            stats.append(.init(label: "Show in", value: "\(max(0, days)) days",
                               accent: days <= 14))
        }

        return DashboardSpec(
            title: profile.name,
            subtitle: profile.species,
            chart: DashboardSpec.ChartSpec(
                label: "Weight", unit: "lbs",
                points: points,
                target: profile.targetWeightLbs,
                targetLabel: "Target"
            ),
            stats: stats,
            actions: [
                .init(label: "Log Visit",   icon: "pawprint",
                      subtitle: "Feeding, health obs",      perform: onVisit),
                .init(label: "Log Weight",  icon: "scalemass",
                      subtitle: "Weigh-in with notes",      perform: onWeight),
                .init(label: "Scan Receipt",icon: "doc.text.viewfinder",
                      subtitle: "Feed, vet, entry fees",    perform: onReceipt),
            ]
        )
    }
}
```

#### `FFADashboardSection`

```swift
struct FFADashboardSection: View {
    @Environment(SpokeController.self) private var spoke

    @State private var weights: [CapturedWeight] = []
    @State private var receipts: [CapturedReceipt] = []
    @State private var showVisitSheet  = false
    @State private var showWeightSheet = false
    @State private var showReceiptSheet = false
    @State private var showProfileEdit = false

    private let store = FFAProfileStore.shared

    var body: some View {
        let spec = store.spec(
            weights: weights,
            receipts: receipts,
            onVisit:   { showVisitSheet   = true },
            onWeight:  { showWeightSheet  = true },
            onReceipt: { showReceiptSheet = true }
        )

        UniversalDashboardSection(
            title: "FFA Project — \(store.profile.name)",
            spec: spec,
            insights: spoke.insights,
            recentLog: AnyView(FFARecentLogView())
        )
        .task {
            weights  = await CaptureStore.shared.weights()
            receipts = await CaptureStore.shared.receipts()
        }
        .sheet(isPresented: $showVisitSheet) {
            FFAVisitSheet { visit in
                Task {
                    _ = try? await FFAEntryOutbox.shared.enqueue(.animalVisit(visit))
                    weights = await CaptureStore.shared.weights()
                }
            }
        }
        .sheet(isPresented: $showWeightSheet) {
            FFAWeightEntrySheet { weight in
                Task {
                    try? await CaptureStore.shared.save(weight)
                    _ = try? await FFAEntryOutbox.shared.enqueue(.weight(weight))
                    weights = await CaptureStore.shared.weights()
                }
            }
        }
        .sheet(isPresented: $showReceiptSheet) {
            // On iOS: file importer for receipt photo. FFAReceiptSheet requires an imageURL.
            // Show file importer first, then pass the URL to FFAReceiptSheet.
            // For simplicity: open FFAProjectRow's receipt path via a file importer.
            EmptyView()  // TODO: wire receipt sheet (requires preloaded image URL)
        }
    }
}
```

> NOTE: The receipt sheet requires a preloaded image URL. Leave the receipt sheet slot as an
> `EmptyView()` with the TODO comment above — do not attempt to implement the full image-pick
> flow. Log Visit and Log Weight are the critical paths.

#### `FFAProfileEditSheet` (in the same file)

Simple form sheet with `TextField` for name and species, `Stepper` for targetWeightLbs
(range 100...500 step 5), `DatePicker` for projectStartDate, and an optional showDate section
(Toggle "Set show date" → DatePicker). Toolbar "Save" button writes to `FFAProfileStore.shared.profile`
and dismisses.

---

## Acceptance criteria

1. Build succeeds with zero new warnings.
2. FFA is a `Section` in the main `List`, not inside Capture.
3. `UniversalDashboardSection` has no FFA imports or FFA type references.
4. `FFADashboardSection` only references `DashboardSpec` — never `Chart` directly.
5. Weight chart renders when ≥ 2 weights exist; target line visible.
6. Stats grid shows correct values from `CaptureStore` (or defaults when empty).
7. Log Visit and Log Weight sheets open and save entries.
8. `FFARecentLogView` is `internal` and referenced from `FFADashboardSection`.

---

## Key paths

| File | Action |
|---|---|
| `AiOSMyFamily/AiOSMyFamily/FFACaptureSection.swift` | MODIFY — remove `private` from `FFARecentLogView` only |
| `AiOSMyFamily/AiOSMyFamily/ContentView.swift` | MODIFY — remove `FFAProjectRow()`, add `FFADashboardSection()` |
| `AiOSMyFamily/AiOSMyFamily/UniversalDashboard.swift` | CREATE — generic renderer only |
| `AiOSMyFamily/AiOSMyFamily/FFADashboardSection.swift` | CREATE — FFA spec builder + section wrapper |
