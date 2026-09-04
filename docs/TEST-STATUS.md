# Test status and known limitations

Honest accounting of what has been verified, where. "Verified" means an automated test passed on
the stated platform, or a manual check was performed there. Nothing below is marked verified on a
physical iPhone yet — the project was authored on a Windows PC and built/tested on GitHub's macOS 26
runners (Xcode 26.6, iOS 26 simulator), which have no microphone and no Apple Intelligence.

## A. Verified by automated tests on macOS / iOS 26 simulator (CI)

Core package (`swift test`, 43 tests):
* Natural-language dates: tomorrow/next Friday/in two hours/September 11/ISO dates, bare-hour rules, vague words with configurable defaults, remainder cleanup.
* Recurrence: weekly, first/last weekday of month, monthly day clamping (Jan 31 → Feb 28), every other week, yearly, end dates, **daily rules across the US daylight-saving change (Nov 1 2026 and Mar 8 2026)**, repeating-trigger eligibility, human descriptions, Codable round trip.
* Deterministic interpreter: all nine acceptance statements plus "every Monday morning", mixed fact+reminder, doctor's-office memory, plumber reschedule, forgotten yesterday, follow-up if incomplete, "later" clarification, complete/delete references, chatter → unknown.
* Recurrence phrase parsing, spoken confirmation wording, fuzzy matching, briefing composer, export schema round trip and newer-schema rejection.

App tests (`xcodebuild test`, iOS simulator):
* Reminder service: create → notification plan at due date; validation errors; duplicate detection; snooze (future and overdue); complete non-recurring removes notification; complete recurring advances (weekly and first-Monday); roll-forward records missed occurrences; forgotten-yesterday; delete / delete-all cancel notifications; follow-up notification; **notification reconciliation repairs missing and removes orphaned requests**; reference matching with day hints; time-zone change keeps the instant.
* Assistant engine (Apple Intelligence unavailable → deterministic path): the nine acceptance statements in sequence including "that" resolution and **explicit confirmation before bulk delete**; mixed sentence; ambiguous "later" saves nothing and offers a pre-filled form; unknown input → Inbox with reason; retry bookkeeping; disambiguation choice; duplicate confirmation; follow-up; briefing; retention purge.
* Model failure paths: model error → rules for clear requests, Inbox for unclear; a prose-only model reply never becomes a false "saved" confirmation; interrupted listening preserves the transcript in the Inbox.
* Storage: in-memory and on-disk `ModelContainer` with the migration plan, relaunch persistence, preferences mirror rows, sample data seeding and delete-all.
* Export/import: full JSON round trip with relationships and notification reconciliation; idempotent re-import; newer format rejected.
* Apple Intelligence: mapping of the three unavailable reasons to messages, error → Inbox reason mapping, provider identity.

## B. Requires a physical iPhone (not yet verified)

These are implemented but could not be exercised on the build server. Test them on an iPhone 15 Pro or newer with iOS 26 and Apple Intelligence enabled, following `docs/SETUP.md`:

1. **Live Apple Intelligence understanding** — the test `AppleIntelligenceTests.testLiveModelCreatesReminderFromNaturalSpeech` runs automatically when the test host has the model; on CI it is *skipped*. Run the nine acceptance statements by voice and by keyboard.
2. **Microphone capture and on-device transcription** (`SpeechAnalyzer`), including the one-time speech-model download, live captions, stop/cancel, and the `SFSpeechRecognizer` fallback.
3. **Spoken responses** (voice selection, speed, stop-speaking).
4. **Audio interruptions** (incoming call while listening → transcript kept in Inbox).
5. **Notification delivery and actions** (Complete, Snooze 1 hour, Open in DayMind) with the app closed.
6. **Daily briefing notification** at the configured time.
7. **Siri phrases, Shortcuts, Action Button, Control Center control, Home/Lock Screen widget** opening straight into listening.
8. **Private CloudKit sync** between two devices (paid developer account required).
9. Accessibility pass on device: VoiceOver on the Talk screen, Dynamic Type XXXL, Reduce Motion, Increase Contrast, dark mode.

## C. Untested / not implemented

* Languages other than English (parsers are English-only; the model supports several languages but DayMind's date words are English).
* Background refresh of the briefing body — the daily notification's text is composed when the app last ran, so it can be stale if the app has not been opened.
* Very long conversations with the model — each request is a fresh session by design; the model sees only the last few turns.
* CloudKit conflict resolution between simultaneous edits (SwiftData's default last-writer-wins applies).
* iPad layout (app targets iPhone only).
* Localized date wording outside en-US (the code uses the device locale, but only en-US strings are asserted in tests).

## Known limitations and deliberate choices

* **Ambiguity policy:** "tomorrow at 3" → 3 PM; bare hours 1–7 mean PM, 8–11 AM. "Next Friday" means the Friday of next week. Both are stated in the confirmation so the user can correct them.
* **"That"/"it":** refers to the most recently created, updated, or singly-listed reminder in this app session.
* **Recurring reminders and iOS:** rules iOS can repeat natively (daily, weekly on one day, monthly on a day ≤ 28, yearly) use one repeating notification. Others ("first Monday", "every other week", multiple weekdays) schedule the next occurrence and reschedule when the app runs or the reminder is completed — if the app is never opened between two occurrences, the second one will not fire until it is.
* **Missed recurring occurrences** are recorded when the app opens and the next occurrence has already passed.
* **Duplicate detection** compares titles fuzzily and requires the same day; it asks rather than blocks.
* **Free Apple ID builds** cannot include iCloud/Push capabilities; remove them as described in SETUP.md.
* **No wake word / background listening** — DayMind cannot replace "Hey Siri". Use the Action Button or a control to get one-tap access.
* **Settings tab:** the five main sections are tabs; Settings opens from the gear icon on each screen (iOS shows at most five tabs before collapsing into "More").

## How to run the tests yourself

```
# Core package (any Mac; also works on Windows/Linux with the Swift toolchain)
swift test --package-path Packages/DayMindCore

# App (Mac with Xcode 26)
xcodegen generate   # only if DayMind.xcodeproj is missing
xcodebuild test -project DayMind.xcodeproj -scheme DayMind -destination 'platform=iOS Simulator,name=iPhone 17'
```

Or in Xcode: **Product → Test** (⌘U). On a physical iPhone with Apple Intelligence the live-model test runs instead of being skipped.
