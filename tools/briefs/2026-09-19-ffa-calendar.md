# FFA Phase 2 — Calendar Integration

## Goal

Add a `FFACalendarSection.swift` to `AiOSMyFamily` that lets Drew schedule and view FFA-related calendar events using EventKit. Three event types: barn days (recurring), show events (one-time, with address), and FFA Parents meetings (one-time, with notes). Show upcoming FFA events for the next 30 days.

## Files to create / modify

| Action   | Path (relative to workspace root)                                      |
|----------|-----------------------------------------------------------------------|
| CREATE   | `AiOSMyFamily/AiOSMyFamily/FFACalendarSection.swift`                  |
| MODIFY   | `AiOSMyFamily/AiOSMyFamily/Info.plist`                                |

---

## FFACalendarSection.swift

### EventKit access

Use `NSCalendarsFullAccessUsageDescription` (already added to Info.plist per this brief). On iOS 17+, call `eventStore.requestFullAccessToEvents()`. Provide a no-op fallback for earlier OS versions.

```swift
import EventKit
import SwiftUI
```

### `FFACalendarManager` (actor)

```swift
actor FFACalendarManager {
    static let shared = FFACalendarManager()
    private let store = EKEventStore()
    private let calendarTitle = "FFA"

    // Returns true if authorized (full or write-only).
    func requestAccess() async -> Bool

    // Creates or re-uses a calendar titled "FFA" in the default event store.
    // Returns nil if access was denied.
    private func ffaCalendar() -> EKCalendar?

    // Saves a new EKEvent to the FFA calendar.
    // For barnDay: recurrenceRule = EKRecurrenceRule daily, endDate nil (indefinite).
    // For showEvent / ffaParentsMeeting: no recurrence rule.
    func schedule(_ event: FFACalendarEvent) async throws

    // Fetches EKEvents from all calendars in the next 30 days, filtered to
    // those whose calendar.title == "FFA" OR whose notes contain "#FFA".
    func upcomingFFAEvents() async -> [EKEvent]
}
```

### `FFACalendarEvent` enum

```swift
enum FFACalendarEventType: String, CaseIterable, Identifiable {
    case barnDay         = "Barn Day"
    case showEvent       = "Show"
    case parentsMeeting  = "FFA Parents Meeting"
    var id: String { rawValue }
}

struct FFACalendarEvent {
    var type: FFACalendarEventType
    var title: String             // editable, pre-filled from type.rawValue
    var startDate: Date
    var endDate: Date             // defaults to startDate + 1 hour
    var location: String          // used for showEvent address
    var notes: String             // free-text; always included
    var isAllDay: Bool            // true for barnDay and parentsMeeting
}
```

### `FFACalendarSection` view

A SwiftUI `View` rendered inside the FFA project's DisclosureGroup (same pattern as `FFACaptureSection`). It has two parts:

**A) Schedule new event button**

Tapping opens `FFAScheduleSheet` (a `.sheet`). The sheet has:
- A `Picker` for `FFACalendarEventType` (segmented style)
- A `DatePicker` for start date/time
- A `DatePicker` for end date/time (hidden for all-day events)
- A `Toggle` "All Day" (pre-set per type; user can override)
- A `TextField` for title (pre-filled from type)
- A `TextField` for location (shown only for `.showEvent`)
- A `TextEditor` for notes (shown always; mandatory for `.parentsMeeting`)
- "Add to Calendar" button → calls `FFACalendarManager.shared.schedule(_:)` → dismisses

**B) Upcoming FFA events list (next 30 days)**

On appear, calls `FFACalendarManager.shared.upcomingFFAEvents()` and stores in `@State var upcomingEvents: [EKEvent]`.

Renders a `List` of results grouped by date. Each row shows:
- Event title
- Date + time (or "All Day")
- Location if non-empty

If `upcomingEvents` is empty, shows a `ContentUnavailableView`-style empty state: "No FFA events in the next 30 days."

If calendar access was denied, show a banner with a "Open Settings" button linking to `UIApplication.openSettingsURLString`.

### Error / permission handling

- Wrap all `FFACalendarManager` calls in `Task { }` blocks inside `.task {}` or button actions.
- Show `@State var errorMessage: String?` as an `.alert` when non-nil.
- Never crash on permission denial — degrade gracefully.

---

## Info.plist modifications

Add ONE new key to `AiOSMyFamily/AiOSMyFamily/Info.plist`:

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>AiOS uses Calendar to schedule barn days, show events, and FFA Parents meetings for your FFA project.</string>
```

The existing plist already has `NSBonjourServices` and `UIBackgroundModes` — preserve them.

---

## Constraints

- **iOS only** (`#if os(iOS)` guard around `UIApplication.openSettingsURLString` usage).
- **No EventKitUI** — use pure EventKit + SwiftUI sheets, no `EKEventEditViewController`.
- **No forced unwraps** — use `guard let` / optional chaining throughout.
- **No Combine** — use Swift async/await and `@State` / `@MainActor` for all state updates.
- **`@MainActor` on the View** body and any `@State` mutation that happens off the main thread.
- Target Swift 6 strict concurrency — actor isolation must compile clean.
- The `FFACalendarManager` actor methods that return/throw must be called with `try await` or `await`.
- Use `Calendar.current.date(byAdding: .day, value: 30, to: Date())!` for the 30-day end bound.

---

## Context — existing FFA code shape (do not modify these files)

`FFACaptureSection.swift` contains `FFAProjectRow` — a DisclosureGroup with camera capture, visit logging, weight logging, and voice notes. `FFACalendarSection` is a **sibling view**, not embedded inside `FFAProjectRow`. It will be placed alongside `FFAProjectRow` in the parent view.

`CapturedAnimalVisit`, `CapturedWeight`, `CapturedReceipt`, `FFAEntryOutbox` all live in `AiOSCore` — the calendar feature does NOT depend on any of them.

---

## Acceptance

Running `swift build` on the `AiOSMyFamily` target must succeed with zero errors.
