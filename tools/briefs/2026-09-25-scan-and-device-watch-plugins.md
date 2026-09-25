# Scan + device-watch tool plugins — brief (2026-09-25)

> **Status: BACKLOG — capture only.** Not scheduled. Queues behind the index-spine work
> (`docs/architecture/2026-09-23-index-spine.md`) and the Studio pipeline slices. Nothing
> here is approved to build yet.

## The ask (Tim, 2026-09-24)
Devices: **Epson FastFoto FF‑680W** (photo scanner), **Brother MFC‑9130CW** (scan + print),
**Canon LBP622Cdw** (print only). None has an AiOS connector today — no ImageCaptureCore,
IPP/CUPS, eSCL, or vendor code anywhere in the repo, and none listed in `ConnectorRegistry`.

"Printer/scanner control" turned out not to be the real goal. The real goals are:
1. **Stop the time-wasters.** Printers/scanners fall off the network, IPs change when machines
   restart, and the scan software loses the device.
2. **Family members scan things themselves, and the scans land in the right folder.** The
   trigger case: a school letter excusing Tim's son's absence for a dentist appointment. It got
   handed to Tim to scan. She should be able to scan it herself from the Brother, the Epson, or
   her phone (AiOSMyFamily), and it should file itself.

The bar for success: nobody in the family needs Tim to scan or file a piece of paper.

## What this is: a tool plugin, not an app or vertical (Tim, 2026-09-25)
**Scan** is a **tool plugin** that can be attached to any Blueprint or app. It is not an app or
vertical of its own. A Blueprint that needs paper in (MyFamily school/medical, FFA receipts,
Finance statements, Tidy Files, a future business vertical) declares a slot for it. The host
app gives it a button. The plugin brings capture, OCR, and routing. The Blueprint brings its
own destinations and routing hints.

The plugin model already exists. Use it; don't build a parallel one:
- **Slot:** `ConnectorSlot` in `Blueprint.connectorSlots`. It accepts a new `ConnectorType.scanner`
  (start as `.custom("scanner")` until it is proven) and carries `defaultFieldMappings`, e.g. an OCR
  hit `tagAs("Scanned Document")`.
- **Wiring:** `BlueprintConfiguration` says which source fills the slot for a given tenant (phone,
  Brother, Epson, watched folder).
- **UI trigger:** `CaptureConnectorID.document`. Host apps resolve it to their own capture sheet.
- **Fetch/normalize:** a `SpokeConnector` conformance (like `VisualScanConnector`), which
  outputs facts, hints, and artifacts with citations.

**Device watch** (item 3 below) is the same kind of thing: a Hub tool plugin that Virtual IT or
a future Home IT Blueprint can attach. It is not a feature of either.

## Spine framing
Per the AGENTS.md thesis, **the scanner is not the product; the inbox router is.** Each device's
only job is getting pages into **one scan inbox on the Hub**. Working out "the right folder"
is spine work, built once and shared by every device and every vertical:

```
phone / Brother / Epson / (future: email attachment, AirDrop, Files drop)
        │
        ▼
  ScanInbox (Hub)  ──►  OCR (Vision)  ──►  classify: who · what · which tenant
                                             │
                          confident ─────────┼───────── ambiguous
                              ▼                               ▼
                    auto-file (FileMover,           review queue (Tidy) —
                    journaled, undoable)            human picks the last 20%
```

Anti-goals:
- Device-specific filing logic ("the Epson saves photos here, the Brother saves letters there").
  If one device needs different routing, the router is missing a feature.
- Blueprint-specific scan code. A Blueprint contributes *configuration* (its destinations,
  entity hints, document types it cares about), never its own copy of scan/OCR/route.

## What already exists (reuse, don't parallel)
| Need | Existing piece |
|---|---|
| Phone document capture | `VNDocumentCameraViewController` wrapper in `AiOSMyFamily/AiOSMyFamily/FFACaptureSection.swift` (~line 103) — **wired only into FFA receipt capture** |
| Mac document capture (file picker) | `AiOSHub/AiOSHub/CaptureSheets.swift` (`CapturedDocument`) |
| Capture-mode id | `CaptureConnectorID.document` (`Capture/CaptureConnector.swift`) — defined, unused |
| OCR + citations | `VisualScanConnector`, `ReceiptOCRParser` |
| Who does this belong to | `FileAttributor` (token-match against tenant entities), `TenantEntityRegistry` |
| What kind of document | `SchemaClassifier` seam, `DocumentCategory` + naming policy (`FileOrganizer`) |
| Moving files safely | `FileMover`, `MoveJournal`, `MoveCollisionPolicy` |
| Human review | Tidy review queue / `TidyProposal` |
| Spoke → Hub transport | `PairedHubClient` / `CaptureOutbox` pattern (as FFA uses) |

**The gap:** nothing ties these together into an *inbox* that takes an arbitrary scanned document
and routes it. That is the core deliverable.

## Work items (proposed order)

### 0. Network hygiene — NOT code, do anytime (~30 min)
The IP-change problem comes from how the network is set up. AiOS shouldn't try to cover it:
- DHCP reservations on the router for all three devices + Studio + NAS.
- Re-add printers on each Mac using the **Bonjour** entry from Add Printer (not an IP address);
  delete stale IP-based queues.
- Re-point Brother's scan software (ICA driver / iPrint&Scan / ControlCenter) and Epson
  FastFoto/ScanSmart at the device name or the new fixed IP.

### 1. Scan plugin core + ScanInbox router — AiOSCore (spine)
- Plugin contract: the `ConnectorType.scanner` slot type, the `SpokeConnector` conformance, and how
  a Blueprint adds routing configuration (destinations/doc types/entity hints) for scans that
  arrive through its slot.
- Input: a scanned document (page image URLs or PDF) + provenance (device / spoke / user).
- OCR via Vision → text + citation.
- Classify **who** (person/entity via `FileAttributor`), **what** (document type via
  `SchemaClassifier` — e.g. school correspondence, medical, receipt), **tenant** (family vs
  business).
- Produce a proposed destination + name per naming policy, with a confidence score.
- High confidence → auto-file through `FileMover` (journaled, undoable). Otherwise → review queue.
- Rule-first; model behind the existing seam. Grounding gate applies: every classification cites
  the OCR text span it was based on.
- Tests: Swift Testing, fixture scans (synthetic letters, no real family documents committed).

**Open design question:** is ScanInbox its own type, or just an `ItemStore` ingest path with a
"from scanner" provenance tag? Prefer the latter if the item store already carries provenance;
don't invent a parallel store.

### 2. First host: "Scan a document" in AiOSMyFamily
MyFamily is only the first app to host the plugin. It doesn't own it. Any app whose Blueprint
declares a scanner slot gets the same button with no extra code.
- Pull the VisionKit scanner out of the FFA-only flow into the shared capture action bound to
  `CaptureConnectorID.document`. FFA's receipt capture then becomes one Blueprint using the
  plugin, not a separate implementation.
- Send pages to the Hub over the existing paired transport (outbox pattern, survives the Hub
  being offline).
- UX: one button, scan, done. Optional one-tap hint ("school", "medical", "receipt") that feeds
  the classifier as a *hint*, never as ground truth.
- Show the result afterwards: "Filed to Family / Kids / <son> / School" or "Needs a quick look".

### 3. Device-watch tool plugin (runs on the Hub)
The plugin runs on the Hub only (see memory: Virtual IT is Hub-only). Virtual IT is its first
host, and a future Home IT Blueprint can attach it too. **Detect and report, don't auto-repair.**
- Keep a list of known devices; check Bonjour presence + resolved IP on a schedule.
- Insight when a device changes IP, disappears, or is only visible from some mesh nodes.
- Printer supplies/queue via the macOS print system (CUPS/IPP): toner, status, stuck jobs,
  cancel. No SNMP unless a real need shows up (Foundation has no SNMP client → would be a
  new dependency, rule 5).
- Overlaps loop 2 ("Printers") of `docs/vertical-candidate-home-it.md`. That vertical should
  *attach* this plugin, not reimplement it.

### 4. Brother + Epson as additional scanner-slot sources
- **Watched-folder route (cheapest, do first):** point the Brother's "Scan to PC/File" output and
  FastFoto/ScanSmart output at the Hub's inbox folder. The Hub ingests new files.
- **ImageCaptureCore route (later, optional):** Hub-driven scans through `ICDeviceBrowser` /
  `ICScannerDevice`. Both vendors ship Apple ICA drivers (Epson ICA 5.8.23 lists macOS 26;
  Brother ICA for MFC‑9130CW), so one Apple-native connector would cover both, no vendor SDKs.
  **Risk:** there are developer reports of ImageCaptureCore not detecting scanners on recent
  macOS — spike on the Studio before committing.

## Device notes (from a quick web check 2026-09-24 — verify on the real hardware)
- **Epson FF‑680W:** built for photo batches through FastFoto; documents through ScanSmart.
  Apple ICA driver available. One search result said it can scan directly to an SMB/NAS folder,
  but the source page was for a different Epson model — **unverified.**
- **Brother MFC‑9130CW:** 2013 model. Apple ICA driver available; works in Image Capture. Probably
  no AirPrint scanning (eSCL). Printing via AirPrint/IPP. Its scan-button workflow depends on
  Brother's Mac software, which is usually what breaks after IP changes.
- **Canon LBP622Cdw:** print only. AirPrint/IPP reports supplies (toner, paper).
- **Prior art (reference, not dependencies):** Home Assistant `brother` (SNMP: toner, drum,
  part life) and `ipp` integrations; community `snmp_printer` (Brother, Canon, others).
  Use them to see which fields matter. Don't route through Home Assistant: it would become a
  second source of truth.

## Pre-build spike (≈1 hr, before any of 1–4)
On the Studio: `system_profiler SPPrintersDataType`, `lpstat -v` (are queues IP- or
Bonjour-based?), open Image Capture (do the Epson and Brother appear?), and check whether IPP
reports supply levels for each printer. The results decide whether step 4's ImageCaptureCore route
is viable and how much of step 3 comes free from CUPS.

## Pushback / risks
- "Remote scanner control" does little: someone still has to put the paper in.
  What's worth controlling remotely is where a scan goes and what happens to it next.
- Most of the value comes from the router (step 1) and the phone (step 2). The Brother and Epson
  integrations matter much less. Don't let step 4 jump the queue because the hardware is there.
- Family documents (kids' school and medical records) are sensitive. They stay on the Hub/NAS
  and never go into committed fixtures. Tests use synthetic documents only.

## Links
`docs/vertical-candidate-home-it.md` (network/printer loop) · `docs/connectors-backlog.md` ·
`docs/architecture/2026-09-23-index-spine.md` · `docs/cli-myfamily-spoke-buildout.md` ·
`docs/cli-virtual-it-process-watchdog.md`
