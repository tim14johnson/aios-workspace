# AiOS — Deploying & Pairing the Apps

How to get the three apps onto your machines, and how to run the device-pairing flow end to end.

## The apps and where they run

| App | Platforms | Role | Runs on |
|---|---|---|---|
| **AiOSHub** | macOS only | **Hub** — the single source of truth; approves devices, serves analysis | Mac Studio (and optionally MBP for a portable demo — see Part 1b; run *one* hub at a time) |
| **AiOSBusiness** | macOS · iOS · iPadOS | Spoke / client (Business tenant) | MBP, iPhone, iPad |
| **AiOSMyFamily** | macOS · iOS · iPadOS | Spoke / client (Family tenant) | MBP, iPhone, iPad |

Both spokes are now **multiplatform native targets** (`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`, `SDKROOT = auto`) — one target builds a real Mac app *and* the iPhone/iPad app. The hub is macOS-native (it uses AppKit + broad file access) and stays Mac-only.

Team: `JTV434B8V4` · Bundle IDs: `com.mazzarothpictures.AiOS{Hub,Business,MyFamily}`

---

## Part 1 — Fastest path to test *today* (direct from Xcode)

No App Store Connect needed. Requires Xcode on the Mac you build from.

### On a Mac (Mac Studio / MBP)
1. Open `AiOS.xcworkspace`.
2. Scheme → **AiOSHub**, destination → **My Mac**, press **▶ Run** (on the Mac Studio).
3. Scheme → **AiOSBusiness**, destination → **My Mac**, **▶ Run**. Repeat for **AiOSMyFamily**.
4. First launch of each: approve the **Local Network** permission prompt.

**To run the apps on the MBP without Xcode there:** build once (Product ▸ Build), then copy the built `.app` from
`~/Library/Developer/Xcode/DerivedData/…/Build/Products/Debug/AiOSBusiness.app`
to the MBP and double-click. The same works for **AiOSHub** and **AiOSMyFamily** — all three are signed with your team and non-sandboxed, so they run as-is. (Dev-signed copies are best for your own machines; for clean distribution to others, see Part 3 — Developer ID.)

Prefer `rsync` over ssh for the copy (avoids the quarantine/app-translocation issues you can hit going through iCloud Drive or a file share). One-time on the MBP: System Settings ▸ General ▸ Sharing ▸ **Remote Login** on. Then per update, from the build Mac:

```bash
xcodebuild -workspace AiOS.xcworkspace -scheme AiOSHub \
  -destination 'generic/platform=macOS' -configuration Release \
  -derivedDataPath /tmp/aios-deploy build

rsync -a --delete /tmp/aios-deploy/Build/Products/Release/AiOSHub.app \
  tim@<mbp-name>.local:/Applications/
```

Repeat with `-scheme AiOSBusiness` / `-scheme AiOSMyFamily` for the spokes. Quit the app on the MBP before syncing (macOS won't cleanly replace a running app), then relaunch. Bump the build number each deploy so you can tell at a glance which build a machine runs.

### Part 1b — Portable demo kit: Hub on the MBP

For an in-person demo with no dependence on venue Wi-Fi or your home network, run the **hub on the MBP itself** alongside (or instead of) the Mac Studio hub, and pair the iPhone/iPad spokes to it. The transport's peer-to-peer (AWDL) support means the devices can talk even with no network in the room; an iPhone hotspot also works as the demo LAN.

1. Install **AiOSHub** on the MBP via the rsync steps above (plus AiOSBusiness/AiOSMyFamily if you're demoing the Mac spoke on the same machine).
2. First launch: approve the **Local Network** prompt.
3. Pair each demo device against the MBP hub (Part 4 flow).

Caveats — read before rehearsing:

- **Run ONE hub per tenant at a time.** Two hubs advertising the same Bonjour service on one LAN means a spoke connects to whichever answers first. When rehearsing at home, quit AiOSHub on the Mac Studio first.
- **Pairing is per-hub, and a spoke holds ONE hub binding per tenant.** Pairing your iPhone with the MBP hub replaces its Mac Studio binding; back home you'll re-pair with the Mac Studio (fast, but don't be surprised).
- **Hub data is per-machine.** Insights, pairing ledger, and organized-file state on the MBP hub are independent of the Mac Studio's. Stage whatever demo data you need on the MBP itself.
- **Rehearse the full pair→analyze flow once on the MBP kit before demo day.**

> **Remote/internet hub access is not supported yet** — spokes find the hub only via Bonjour (LAN/peer-to-peer). Reaching a home hub over the internet (fixed port + manual hub address + Tailscale) is on the backlog as a priority.

### On iPhone / iPad
1. Connect the device to a Mac running Xcode.
2. On the device: **Settings ▸ Privacy & Security ▸ Developer Mode ▸ On** (this row only appears after Xcode has targeted the device at least once; restart when prompted).
3. In Xcode: scheme **AiOSBusiness**, destination = your device, **▶ Run**. First launch: **Settings ▸ General ▸ VPN & Device Management** → trust your developer cert. Approve Local Network.

> Free Apple ID signing expires after 7 days (app stops launching until re-run). Your paid team membership signs for a year.

---

## Part 2 — TestFlight (the "appears as a normal app, no Xcode" path)

TestFlight distributes through App Store Connect. Testers install via the **TestFlight app** (iPhone/iPad) or **TestFlight for Mac** — no Xcode required for them. Needs the **paid Apple Developer Program** (you have team `JTV434B8V4`).

### ⚠️ Platform reality — read first
- **iOS / iPadOS → TestFlight is straightforward.** Do this.
- **macOS → TestFlight uses the Mac App Store pipeline, which *requires the App Sandbox*.** Your Mac apps are currently **non-sandboxed** (`ENABLE_APP_SANDBOX = NO`). To ship the Mac builds via TestFlight you must first sandbox them and add entitlements (network client/server for Bonjour + TLS, keychain access, and — for the hub — security-scoped bookmarks for the folders it organizes). The hub is the heavy one (it moves files across the disk and spawns the Plaud MCP subprocess), so sandboxing it is a real task, not a toggle.
- **Recommended split:** iPhone/iPad via **TestFlight**; Mac via **Developer ID notarization** (Part 3) or a copied dev build (Part 1). Only invest in sandboxing if you specifically want the Mac apps *in TestFlight/Mac App Store*.

### 2a. One-time App Store Connect setup (per app)
1. [developer.apple.com](https://developer.apple.com) ▸ **Certificates, Identifiers & Profiles ▸ Identifiers**: confirm each bundle ID exists and has the capabilities the app uses (App Groups/iCloud/Push as applicable). Enable the **macOS** platform on the identifier if you'll ship a Mac build.
2. [App Store Connect](https://appstoreconnect.apple.com) ▸ **Apps ▸ ➕ New App**: create one record per app (AiOSBusiness, AiOSMyFamily). Select the platforms (iOS, and macOS if sandboxed). One record can host both an iOS and a macOS build under the same bundle ID.

### 2b. Upload a build (per app, per platform)
In Xcode:
1. Set the scheme (e.g. **AiOSBusiness**) and destination to **Any iOS Device (arm64)** (for the iOS build) — or **Any Mac** for a Mac build.
2. **Product ▸ Archive**.
3. In the Organizer: **Distribute App ▸ App Store Connect ▸ Upload**. Let Xcode manage signing.
4. Repeat with the other destination/platform, and for **AiOSMyFamily**.

### 2c. Export-compliance note (don't skip)
These apps use **CryptoKit** for the custom pairing PSK + **TLS**. On first upload App Store Connect asks about encryption. TLS/standard-crypto usually qualifies for the exemption, but the *custom* pairing crypto means you should answer accurately (you may need a one-time self-classification / CCATS, or confirm you qualify for the exemption). You can pre-answer by adding to each app's Info.plist:
```xml
<key>ITSAppUsesNonExemptEncryption</key><false/>
```
only if you confirm it qualifies — otherwise leave it and answer in the portal.

### 2d. Invite yourself as a tester
1. App Store Connect ▸ your app ▸ **TestFlight** tab. Builds appear after a few minutes of processing.
2. **Internal Testing**: add yourself/team under **Users and Access** (up to 100 internal testers). Internal builds skip Beta App Review and are available immediately.
3. Install: **TestFlight** app on iPhone/iPad; on Mac, install **TestFlight** from the App Store and sign in.

---

## Part 3 — Clean Mac distribution without the App Store (Developer ID)

For "a normal Mac app I can hand to any Mac" without sandboxing:
1. Xcode ▸ scheme ▸ **Any Mac** ▸ **Product ▸ Archive**.
2. Organizer ▸ **Distribute App ▸ Direct Distribution** (Developer ID) ▸ Upload for **notarization**.
3. Once notarized, export the `.app`/`.dmg`; it runs on any Mac past Gatekeeper. No sandbox required, no App Store.

This is the least-friction way to get the hub + spokes onto the Mac Studio and MBP as real, shareable Mac apps.

---

## Part 4 — Verifying the pairing flow (once installed)

1. **Mac Studio:** launch **AiOSHub**. The window's **Devices** section shows **Hub id ….**.
2. **Client (MBP / iPhone / iPad):** launch **AiOSBusiness** ▸ **Hub Connection** ▸ **Pair with Hub**. It shows "waiting…" and a **6-digit code**.
3. **Hub:** the client appears under **Business ▸ Pending** with a **6-digit code**. **Confirm the two codes match** (this rules out a man-in-the-middle), then **Approve**.
4. The client flips to **Paired**; tap **Analyze** → analysis runs on the hub over an encrypted, device-pinned (TLS-PSK) connection.
5. Repeat with **AiOSMyFamily** (it pairs against the separate **Family** service).

### If pairing doesn't connect
- Both machines must be on the **same Wi-Fi/LAN subnet** (not an isolated "Guest" network; AWDL/peer-to-peer is enabled but same-subnet is most reliable).
- Approve the **Local Network** permission on each client (macOS: System Settings ▸ Privacy & Security ▸ Local Network).
- An **unapproved** or denied device *cannot* connect — that's by design; approve it on the hub first.
- Family and Business are **separate Bonjour services** (`_aios-fam._tcp` / `_aios-biz._tcp`); a device paired for one tenant is invisible to the other.
