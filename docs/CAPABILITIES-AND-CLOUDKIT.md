# Xcode capabilities, entitlements and CloudKit

## Capabilities used

| Capability / key | Target | Why | Free Apple ID? |
| --- | --- | --- | --- |
| Microphone (`NSMicrophoneUsageDescription`) | DayMind | Hear the user while the Talk button is active | Yes |
| Speech Recognition (`NSSpeechRecognitionUsageDescription`) | DayMind | Fallback recognizer (`SFSpeechRecognizer`) | Yes |
| Notifications (`NSUserNotificationsUsageDescription`) | DayMind | Local reminder notifications | Yes |
| URL scheme `daymind://` | DayMind | Deep links from widget, control, Siri, notifications | Yes |
| App Intents / App Shortcuts | DayMind, DayMindControls | Siri, Shortcuts, Action Button, Controls | Yes (no extra entitlement) |
| WidgetKit extension (`com.apple.widgetkit-extension`) | DayMindControls | Widget + Control Center control | Yes |
| iCloud → CloudKit (`com.apple.developer.icloud-services`, container `iCloud.com.dabkowski.DayMind`) | DayMind | Optional private sync | **Paid program only** |
| Push Notifications (`aps-environment`) | DayMind | CloudKit silent pushes so devices learn about changes | **Paid program only** |
| Background mode `remote-notification` | DayMind | Receive CloudKit change pushes | Yes (works only with the above) |

Everything is declared in `project.yml` (which generates `Info.plist` and `DayMind.entitlements`).
The privacy manifest is `DayMind/Resources/PrivacyInfo.xcprivacy`.

No other entitlements. In particular there is **no** network-dependent AI, no advertising SDK, no
analytics SDK, no App Groups, no HealthKit, no location.

## Free Apple ID (personal team)

Remove the **iCloud** and **Push Notifications** capabilities in **Signing & Capabilities** for the
DayMind target (see SETUP.md Part 5 step 6). DayMind detects the missing entitlement and shows
"iCloud sync: Unavailable — the iCloud capability is not enabled for this build". Everything else works.

## Paid Apple Developer Program — enabling private CloudKit sync

1. In Xcode, select the **DayMind** target → **Signing & Capabilities**.
2. If **iCloud** is not listed, click **+ Capability** → **iCloud**. Tick **CloudKit**.
3. Under **Containers** click **+** and enter `iCloud.com.dabkowski.DayMind` (or `iCloud.` + your bundle identifier; if you change it, also change `com.apple.developer.icloud-container-identifiers` in `project.yml`).
4. Click **+ Capability** → **Push Notifications** (Xcode adds `aps-environment`). Also add **Background Modes → Remote notifications** if it is not already ticked.
5. Build once on a real iPhone signed into iCloud. SwiftData creates the CloudKit schema automatically in the **Development** environment.
6. In DayMind → Settings turn on **Sync with private iCloud** and relaunch the app. The status row shows "On — syncing with your private iCloud".
7. Before TestFlight/App Store: open [CloudKit Console](https://icloud.developer.apple.com/) → your container → **Deploy Schema Changes** to production. Without this step production builds cannot sync.

### How sync behaves

* Uses the user's **private** CloudKit database only. No public or shared database. Nobody but the user's own devices can read the data.
* Core functionality never depends on iCloud: the local store is always the source of truth; if the CloudKit container cannot be created the app silently uses local-only storage and reports it in Settings.
* Settings ride along: `SettingsStore` mirrors into the `UserPreferences` / `BriefingSettings` rows, and a newer row from another device is adopted at launch.
* Notifications are per device; each device reconciles its own notification requests at launch from the synced reminders.

### Model rules kept for CloudKit compatibility

* Every attribute has a default value or is optional.
* No `@Attribute(.unique)`; uniqueness is enforced in the services.
* All relationships are optional; inverses are declared once.
* No ordered relationships.

## Other build settings worth knowing

* Deployment target iOS 26.0 (Foundation Models and SpeechAnalyzer require it).
* Swift language mode 5 with minimal strict concurrency (for maximum compatibility with the 26 SDKs); the code uses `@MainActor` isolation for all UI-facing state.
* Bundle identifiers: app `com.dabkowski.DayMind`, extension `com.dabkowski.DayMind.Controls`. Change both together.
