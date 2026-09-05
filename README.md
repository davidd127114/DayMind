# DayMind

A private, on-device personal butler for reminders and long-term memory on iPhone.
Tap the butler, speak (or type, or attach a photo of an appointment card), and it files it:
reminders with real recurrence rules and local notifications, or permanent memories about people,
projects and decisions. Two screens: **Butler** and **My Book**.

**No paid AI. No API keys. No accounts.** Understanding runs on Apple Intelligence (Apple's
Foundation Models framework) on the iPhone itself. When Apple Intelligence is unavailable, a
deterministic offline parser and a manual form keep everything working.

> Status: Milestones 1–5 implemented. CI on GitHub's macOS 26 runner is green: 44 core tests and
> 42 app tests pass on the iOS 26 simulator (1 live-model test skipped there). Voice capture, spoken
> replies, notification delivery, Siri/Action Button and CloudKit still need a physical iPhone —
> see [docs/TEST-STATUS.md](docs/TEST-STATUS.md) for the exact split.

## What it does

| You say | DayMind does |
| --- | --- |
| "Remind me tomorrow at 3 PM to call Michael." | Creates a reminder, schedules a notification, links the person "Michael", confirms the exact date and time. |
| "Every first Monday of the month at 9 AM, remind me to pay rent." | Creates a recurring reminder with a real "first Monday" rule. |
| "Remember that Michael prefers afternoon appointments." | Saves a permanent memory (category: preference). |
| "What did I tell you about Michael?" | Searches memories and reads them back. |
| "Change tomorrow's call to Friday at 10." | Finds the matching reminder and moves it; asks which one if several match. |
| "Snooze that for two hours." | Snoozes the reminder just discussed. |
| "What am I forgetting today?" | Lists today's and overdue reminders. |
| "Save this under the kitchen renovation project." | Files the last saved item under a project. |
| "Delete all of my reminders." | Asks for explicit confirmation before deleting anything. |

## Requirements

* **iPhone with Apple Intelligence** (iPhone 15 Pro or newer, iOS 26 or later) for voice understanding.
  Any iPhone on iOS 26 can still use reminders, notifications, notes, search and the manual form.
* **A Mac with Xcode 26** to build and install (this project cannot be built on Windows or Linux;
  the repository's GitHub Actions workflow builds and tests it on a free macOS runner).
* A free Apple ID for installing on your own phone. A paid Apple Developer account is needed only
  for iCloud sync, TestFlight and the App Store.

## Documentation

* [docs/SETUP.md](docs/SETUP.md) — beginner, step-by-step: open the project, run in the simulator, install on your iPhone.
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit, the AI provider protocol, tool calling, data model.
* [docs/APPLE-INTELLIGENCE.md](docs/APPLE-INTELLIGENCE.md) — compatibility, availability states, what happens without it.
* [docs/CAPABILITIES-AND-CLOUDKIT.md](docs/CAPABILITIES-AND-CLOUDKIT.md) — Xcode capabilities, entitlements, CloudKit setup.
* [docs/PRIVACY-AND-SECURITY.md](docs/PRIVACY-AND-SECURITY.md) — data handling, permissions, privacy manifest.
* [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) — TestFlight / App Store preparation.
* [docs/TEST-STATUS.md](docs/TEST-STATUS.md) — simulator-tested vs device-tested vs untested, known limitations.

## Repository layout

```
project.yml                 XcodeGen spec (generates DayMind.xcodeproj; CI commits the result)
DayMind/                    iOS app (SwiftUI, SwiftData, Foundation Models, Speech, UserNotifications, App Intents)
DayMindControls/            Widget + Control Center / Action Button control extension
Shared/                     Code compiled into both the app and the extension
Packages/DayMindCore/       Pure-Swift package: date parsing, recurrence engine, offline interpreter, export format
DayMindTests/               App tests (services, engine, storage, export, Apple Intelligence availability)
docs/                       Documentation
.github/workflows/ci.yml    Builds the core package and the app, runs all tests on macOS 26 + iOS 26 simulator
```

## License

MIT — see [LICENSE](LICENSE).
