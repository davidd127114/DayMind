import AppIntents
import Foundation

/// Opens DayMind straight into voice capture. Shared by the app (Siri / Shortcuts / Action Button)
/// and the Controls extension (Control Center button, Lock Screen control). Deliberately has no
/// dependency on app types so it compiles in both targets.
struct OpenVoiceCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to DayMind"
    static let description = IntentDescription("Opens DayMind and starts listening for a reminder or note.")
    static let openAppWhenRun = true
    static let isDiscoverable = true

    static let deepLink = URL(string: "daymind://talk?autostart=1")!

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.deepLink))
    }
}
