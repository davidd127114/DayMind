# DayMind architecture

## Goals that shaped the design

1. **Zero recurring cost.** The only "AI" is Apple's on-device model via the Foundation Models framework. There is no network client for any AI service and no place to put an API key.
2. **The database is the memory.** The language model never holds state between requests. Every reminder and memory is a SwiftData row; the model only sees a short context block per request.
3. **Never claim what did not happen.** Tools write to the database and record what they did in an `ActionLog`. The spoken confirmation is composed from that log by deterministic code, not from the model's prose.
4. **Degrade, don't die.** Without Apple Intelligence, a deterministic parser handles the common phrasings and a manual form handles the rest. Anything not understood goes to the Inbox.

## Layers

```
┌───────────────────────── SwiftUI ─────────────────────────┐
│ Today · Talk · Memories · Projects · Inbox · Settings      │
└───────────────┬───────────────────────────────┬───────────┘
                │                               │
        VoiceController                  AssistantEngine (orchestrator)
   (mic, SpeechAnalyzer/SFSpeech,          │        │
    AVSpeechSynthesizer, states)     AIProvider   RuleBasedInterpreter (DayMindCore)
                                    (Apple on-device)      │
                                           │  tool calls   │ deterministic
                                           ▼               ▼
                                     AssistantActions  ◄────┘   validates every argument,
                                           │                    records ActionRecords
                                           ▼
        ReminderService · MemoryService · ProjectService · PersonService · InboxService
        ConversationService · BriefingService · ExportImportService
                                           │
                              DataStore (SwiftData ModelContainer)   NotificationScheduler (UNUserNotificationCenter)
```

### DayMindCore (Swift package, no Apple-only frameworks)

Pure logic that is unit-tested on any platform (it was developed and tested on Windows with the Swift toolchain, then on macOS in CI):

* `NaturalDateParser` — English date/time phrases → exact `Date` using `Calendar` (DST-safe). Configurable morning/afternoon/evening/night times. Bare hours 1–7 are PM, 8–11 AM, 12 noon. "next Friday" = the Friday of next week; "Friday" = the coming Friday.
* `RecurrenceParser` + `RecurrenceRule` — "every first Monday of the month", "every other week", "weekdays", "every September 11" → a rule with `nextOccurrence(after:anchor:calendar:)`, a human description, and `repeatingTriggerComponents` when iOS can repeat it natively.
* `RuleBasedInterpreter` — the offline understanding path: create reminder / save memory / both, search, list, complete, snooze, reschedule, follow-up, delete, delete-all, assign to project, briefing.
* `TextMatching` — fuzzy matching to find "the plumber reminder".
* `BriefingComposer` — short spoken briefing text.
* `ExportSchema` — versioned JSON backup DTOs.
* `SpokenFormatter` — the exact confirmation wording ("Friday, September 11 at 10:00 AM").

### App: models (`DayMind/Models`)

`DayMindSchemaV1` is a `VersionedSchema`; `DayMindMigrationPlan` is a `SchemaMigrationPlan` (currently one stage; future versions append lightweight/custom stages). Models: `Reminder`, `Memory`, `Person`, `Project`, `ConversationTurn`, `InboxItem`, `UserPreferences`, `BriefingSettings`. All fields have defaults or are optional and relationships are optional, which is what CloudKit-backed SwiftData requires. Complex values (recurrence, snooze history, missed occurrences, related IDs) are JSON blobs decoded through computed properties in `ModelExtensions.swift`.

### App: services (`DayMind/Services`)

* `DataStore` — builds the `ModelContainer`; tries CloudKit when enabled and falls back to local with a visible reason.
* `ReminderService` — the only writer of reminders. Validates, detects duplicates, creates/updates/snoozes/completes/deletes, rolls recurring reminders forward (recording missed occurrences), reconciles notifications at launch, and finds reminders from a `ReminderReference` ("tomorrow's plumber reminder", "that").
* `NotificationScheduler` — `NotificationScheduling` protocol (mocked in tests) and `LocalNotificationScheduler` over `UNUserNotificationCenter`. `NotificationPlanner` turns a reminder into `NotificationPlan`s: a repeating calendar trigger for simple rules, single next occurrence for complex ones, plus an optional follow-up. Category `DAYMIND_REMINDER` carries Complete / Snooze 1 hour / Open actions.
* `MemoryService`, `ProjectService`, `PersonService`, `InboxService`, `ConversationService` (applies transcript retention), `BriefingService` (composes and schedules the daily briefing), `ExportImportService` (JSON, merge by UUID), `SettingsStore` (UserDefaults, mirrored to `UserPreferences` rows so settings can sync), `SampleData`.

### App: AI (`DayMind/AI`)

* `AIProvider` protocol — `availability()`, `process(request, actions)`, `prewarm()`. Includes a human-readable `costAndPrivacyNote`. The only implementation is `AppleIntelligenceProvider`.
* `AppleIntelligenceProvider` — two-stage use of `LanguageModelSession`:
  1. **Classify** with `respond(to:generating: IntentClassification.self)` (a `@Generable` struct) to pick a small tool group and detect genuine ambiguity.
  2. **Act** with a session whose `tools:` are the strictly typed `Tool` implementations for that group and `instructions` containing the current date/time/time zone, the reminder currently "in focus" (for "that"/"it"), the last saved memory and the last few turns.
  `SystemLanguageModel.default.availability` is mapped to user-facing reasons (device not eligible, Apple Intelligence off, model downloading). `GenerationError` cases map to `AIProcessingError` and to Inbox reasons.
* `FoundationModelTools` — the 13 tools (`createReminder`, `updateReminder`, `completeReminder`, `deleteReminder`, `snoozeReminder`, `listReminders`, `saveMemory`, `updateMemory`, `deleteMemory`, `searchMemories`, `createProject`, `associateItemWithProject`, `getDailyBriefing`). Arguments are `@Generable` with `@Guide` constraints. Dates/times/recurrence are passed as **the words the user said**; `AssistantActions` converts them with the deterministic parsers because small models are unreliable at calendar math.
* `AssistantActions` — shared by the model tools and the deterministic path. Validates, calls services, records `ActionRecord`s, returns a short text result for the model. Bulk deletion and duplicates become `PendingAction`s that need a tap or a "yes".
* `AssistantEngine` — orchestration and safety nets: pending confirmations, disambiguation, focus tracking, falling back to rules when the model errs or answers in prose without acting, saving to the Inbox when nothing could be done.
* `ResponseComposer` — deterministic confirmation sentences from `ActionRecord`s.

### App: voice (`DayMind/Speech`)

* `VoiceController` — state machine (`idle`, `requestingPermission`, `listening`, `processing`, `saving`, `speaking`, `success`, `failure`), interruption handling, on-device disclosure.
* `AnalyzerSpeechRecognizer` — iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (on-device; downloads Apple's model assets once via `AssetInventory`). Volatile results give live captions; final results are accumulated.
* `LegacySpeechRecognizer` — `SFSpeechRecognizer` fallback; requests on-device recognition when supported and discloses when Apple's speech service is used.
* `SpeechOutputService` — `AVSpeechSynthesizer` with voice selection and rate.
* `AudioSessionManager` / `AudioCaptureEngine` — `.playAndRecord` session, `AVAudioEngine` tap. Audio is never written to disk.

### System integration

* App Intents (`DayMind/Intents`): `AddReminderIntent`, `SaveMemoryIntent`, `TodayBriefingIntent`, `NextDueIntent`; `DayMindShortcuts` provides Siri phrases. `OpenVoiceCaptureIntent` (in `Shared/`) opens `daymind://talk?autostart=1` and is used by Siri, the Action Button, the Control Center control and the widget.
* `DayMindControls` extension: `TalkControl` (`ControlWidget`) and `TalkWidget` (`Widget`).
* `NotificationDelegate`: notification actions call `ReminderService` directly — no AI involved.
* URL scheme `daymind://` routes: `talk`, `today`, `inbox`, `memories`, `projects`, `settings`, `reminder/<uuid>`.

## Request lifecycle (voice)

1. Tap mic → `VoiceController.startListening()` → live transcript.
2. Tap again → `stopListening()` finalizes → `AssistantEngine.handle(text, source: .voice)`.
3. Engine logs the user turn, runs `RuleBasedInterpreter` (always), then:
   * bulk delete → confirmation, never through the model;
   * model available → `AppleIntelligenceProvider.process` → tools → `ActionLog`;
   * model unavailable/failed → deterministic path for clear requests, Inbox otherwise.
4. `ResponseComposer` builds the reply from what actually happened; cards show each `ActionRecord`.
5. `VoiceController.speak()` reads the reply; the assistant turn is logged.

## Testing strategy

* `DayMindCoreTests` (43 tests): date parsing, recurrence incl. DST, interpreter acceptance statements, composer, export.
* `DayMindTests`: services with a mock notification scheduler, engine acceptance script end-to-end in deterministic mode, model failure paths, disambiguation, duplicate handling, export/import, schema/migration, sample data, Apple Intelligence availability mapping, and a live-model test that is skipped (reported as skipped) when the host has no Apple Intelligence.
