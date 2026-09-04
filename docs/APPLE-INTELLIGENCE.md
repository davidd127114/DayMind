# Apple Intelligence compatibility

DayMind's understanding runs on Apple's on-device foundation model through the **Foundation Models**
framework (`import FoundationModels`, iOS 26+). Requests never leave the phone and there is no charge.

## Which iPhones

| iPhone | Apple Intelligence | DayMind voice understanding |
| --- | --- | --- |
| iPhone 15 Pro / Pro Max, iPhone 16 (all), iPhone 17 (all), and later | Yes | Full |
| iPhone 15 / 15 Plus, iPhone 14 and older, iPhone SE | No | Offline rules + manual form; reminders, notifications, memories and search all work |

Requirements on a supported iPhone: iOS 26 or later, Apple Intelligence turned on in
**Settings → Apple Intelligence & Siri**, model downloaded (needs Wi-Fi, charging and free space),
and a supported language (English is supported; DayMind's parsers are English-only in this version).

## Availability states DayMind handles

`SystemLanguageModel.default.availability` is checked before every request and shown in Settings and on the Talk screen:

| State | What the user sees | What still works |
| --- | --- | --- |
| `.available` | "Apple Intelligence — on this iPhone" | Everything |
| `.unavailable(.deviceNotEligible)` | "This iPhone does not support Apple Intelligence." (no retry offered) | Offline rules, manual form, notifications, search, Inbox |
| `.unavailable(.appleIntelligenceNotEnabled)` | "Apple Intelligence is turned off. Turn it on in Settings → Apple Intelligence & Siri." + Retry | same |
| `.unavailable(.modelNotReady)` | "The model is still downloading or preparing. Keep the iPhone on Wi-Fi and charging." + Retry | same |
| any other reason | "Temporarily unavailable. Try again later." + Retry | same |

Errors during a request (`LanguageModelSession.GenerationError`) are mapped to plain messages:
input too long, blocked by Apple's on-device safety filter, unsupported language, busy, decoding
failure. In every case the user's words are preserved in the **Inbox** with the reason, and clear
requests are still executed by the deterministic parser.

## What the model does and does not do

The model **does**: classify the request, pick typed tools, extract the title, the date/time words,
recurrence words, people, project and category, and phrase short replies for questions.

The model **does not**: compute dates (Swift does, from the words it extracted), decide what was
saved (the action log does), delete anything in bulk (always requires a tap), or store memory in its
context (the database does). This keeps behaviour predictable with a small on-device model.

## Simulator

The iOS simulator only has the model when the Mac itself runs macOS 26 with Apple Intelligence
enabled and downloaded. Otherwise the app shows the "Offline mode" banner in the simulator, which is
expected. The GitHub Actions build server has no Apple Intelligence, so the live-model test in
`AppleIntelligenceTests` is reported as **skipped** there, not as passed.

## Adding another provider later

Implement `AIProvider` (`availability()`, `process(request, actions)`, `prewarm()`), and pass it to
`AppEnvironment`. Providers call the same `AssistantActions`, so every safety rule (validation,
action log, confirmations) applies automatically. The shipped app enables only the Apple provider and
contains no network AI client.
