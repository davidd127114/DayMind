# TestFlight / App Store preparation checklist

Requires the paid Apple Developer Program ($99/year).

## Before archiving

- [ ] Change bundle identifiers to your own (`project.yml` → `PRODUCT_BUNDLE_IDENTIFIER` for both targets, and the iCloud container), run `xcodegen generate`.
- [ ] Set `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- [ ] Replace the placeholder app icon (`DayMind/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, 1024×1024, no alpha).
- [ ] Decide on iCloud sync: keep the iCloud + Push capabilities (and deploy the CloudKit schema to Production in CloudKit Console) or remove them.
- [ ] Run the full test suite: `xcodebuild test -scheme DayMind -destination 'platform=iOS Simulator,name=iPhone 17'` and on a physical iPhone.
- [ ] Walk through `docs/TEST-STATUS.md` on a physical Apple Intelligence iPhone and tick the device-tested items.
- [ ] Verify all permission strings read well on device.
- [ ] Check Dynamic Type at the largest accessibility size, VoiceOver on the Talk screen, Reduce Motion, Increase Contrast, dark mode.

## App Store Connect

- [ ] Create the app record with the same bundle identifier.
- [ ] Privacy: "Data Not Collected". Tracking: No. Mention optional iCloud sync in the description.
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = false` is already set (only standard Apple encryption).
- [ ] Age rating: 4+.
- [ ] Screenshots for 6.9" and 6.5" iPhones (Today, Talk with a confirmation card, Memories, Settings status).
- [ ] App Review notes: explain that understanding uses Apple Intelligence on device, that the app works without it, and how to test without a microphone (keyboard button on Talk). Provide a sample script (the nine acceptance statements).
- [ ] Siri/App Intents: nothing to configure; phrases come from `DayMindShortcuts`.

## Archive and upload

1. Xcode: select **Any iOS Device (arm64)** → **Product → Archive**.
2. Organizer → **Distribute App** → **App Store Connect** → **Upload**. Let Xcode manage signing.
3. In App Store Connect → TestFlight, add internal testers (up to 100). External testers need a short Beta App Review.
4. Collect feedback; iterate; then **Submit for Review** on the App Store tab.

## Post-release

- [ ] Keep `DayMindMigrationPlan` in step with any model change: add `DayMindSchemaV2`, append a migration stage, add a test that opens a V1 store.
- [ ] Re-run the acceptance script after each iOS release; Foundation Models behaviour can change with the OS.
