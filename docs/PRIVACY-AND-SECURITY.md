# Privacy and security notes

## Summary

* **Local-first.** All reminders, memories, people, projects, inbox items and conversation history live in a SwiftData store inside the app's sandbox on the iPhone.
* **Optional private iCloud.** Sync, if enabled, uses the user's private CloudKit database only. The developer has no server and cannot read user data.
* **No third-party AI, no API keys.** The only model is Apple's on-device model via Foundation Models. The app contains no HTTP client for AI, no credential storage for AI, and no cloud fallback.
* **No analytics, no advertising, no tracking.** The privacy manifest declares `NSPrivacyTracking = false`, no collected data types and no tracking domains.
* **No raw audio retention.** Microphone audio flows through `AVAudioEngine` into the recognizer and is discarded. Nothing is written to disk.
* **Transcript retention is configurable.** Settings → Privacy: never / 7 days / 30 days / until deleted. The rule applies to conversation history and to the "original words" stored on reminders and memories.
* **Export and delete.** Settings → Data: JSON backup export, import, and "Delete all data" (with confirmation) which also cancels every notification and resets settings.

## Permissions requested and why

| Permission | When asked | Purpose string (Info.plist) |
| --- | --- | --- |
| Microphone | First tap of the microphone button | Hear reminders/notes while the button is active; audio is transcribed and discarded |
| Speech Recognition | Only if the `SFSpeechRecognizer` fallback is used | Turn speech into text; on-device on supported iPhones |
| Notifications | When the user taps "Allow notifications" in Settings or on first reminder creation | Local reminder notifications |
| iCloud | Implicit via the signed-in account when sync is enabled | Private sync |

No location, contacts, calendar, photos, camera, Bluetooth, or health access.

## Speech recognition disclosure

* Preferred engine: `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26) — fully on-device. Apple's speech model assets are downloaded once from Apple.
* Fallback: `SFSpeechRecognizer` with `requiresOnDeviceRecognition` when the device supports it. If it does not, recognition uses **Apple's** speech service (operated by Apple under the user's Apple terms, not a third-party or paid API). DayMind states which engine is active in Settings → Voice and on the Talk screen.

## Logging

`os.Logger` is used with category names; user content is never interpolated into log messages
except as `privacy: .public` error descriptions from the system. Titles, transcripts and memory
contents are not logged.

## Threat notes

* **Model prompt content:** the user's own words plus a short context block (date, focus reminder title, last memory title, recent turns). All processed on device.
* **Tool argument validation:** every tool argument is re-validated in Swift (`AssistantActions` / services): titles trimmed and length-checked, dates bounded to ten years, minutes clamped, enum strings mapped with safe defaults, IDs parsed as UUIDs.
* **Destructive actions:** bulk deletion always requires an explicit tap or "yes" after the question is shown; nothing is deleted before that. Duplicate-looking reminders require confirmation.
* **Backups:** the JSON export contains everything, in clear text, by design (the user owns it). Advise users to store backups where they keep other private files. Import validates the schema version.
* **Keychain:** not used in this version because the app stores no secrets. If a future provider needed a token, `AIProvider` implementations should store it in the Keychain, never in UserDefaults or source.

## App Store privacy questionnaire (Nutrition label)

* Data collected: **None** (nothing leaves the device to the developer).
* If iCloud sync is on, data goes to the user's own iCloud — this is not "collection" by the developer, but mention iCloud sync in the App Store description.
* Tracking: **No**.
