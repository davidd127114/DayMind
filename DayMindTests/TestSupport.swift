import Foundation
import XCTest
import UserNotifications
import DayMindCore
@testable import DayMind

/// Records what would have been scheduled, without touching the real notification center.
@MainActor
final class MockNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    var scheduled: [String: NotificationPlan] = [:]
    var removed: [String] = []
    var briefing: (time: TimeOfDay, title: String, body: String)?
    var authorized = true

    func requestAuthorization() async -> Bool { authorized }
    func authorizationStatus() async -> UNAuthorizationStatus { authorized ? .authorized : .denied }
    func apply(plans: [NotificationPlan]) async { for p in plans { scheduled[p.identifier] = p } }
    func remove(identifiers: [String]) async {
        for id in identifiers { scheduled.removeValue(forKey: id); removed.append(id) }
    }
    func pendingReminderIdentifiers() async -> Set<String> { Set(scheduled.keys.filter { $0.hasPrefix("reminder-") }) }
    func scheduleBriefing(at time: TimeOfDay, title: String, body: String) async { briefing = (time, title, body) }
    func cancelBriefing() async { briefing = nil }
    func removeAll() async { scheduled = [:] }
}

/// Simulates an iPhone without Apple Intelligence (or with it switched off).
@MainActor
final class UnavailableProvider: AIProvider {
    let id = "test.unavailable"
    let displayName = "Unavailable test provider"
    let costAndPrivacyNote = "Test only"
    var reason = "Apple Intelligence is turned off."
    func availability() -> AIAvailability { .unavailable(reason: reason, suggestion: "Turn it on in Settings.", canRetryLater: true) }
    func process(_ request: AssistantRequest, actions: AssistantActions) async throws -> ProviderResponse {
        throw AIProcessingError.modelUnavailable(reason)
    }
    func prewarm() async {}
}

/// A provider that claims to be available but fails mid-request (model error path).
@MainActor
final class FailingProvider: AIProvider {
    let id = "test.failing"
    let displayName = "Failing test provider"
    let costAndPrivacyNote = "Test only"
    var error: AIProcessingError = .modelFailed("simulated failure")
    func availability() -> AIAvailability { .available }
    func process(_ request: AssistantRequest, actions: AssistantActions) async throws -> ProviderResponse { throw error }
    func prewarm() async {}
}

/// A provider that is available but never calls tools and answers in prose (tests the safety net).
@MainActor
final class ChattyProvider: AIProvider {
    let id = "test.chatty"
    let displayName = "Chatty test provider"
    let costAndPrivacyNote = "Test only"
    var reply = "Sure, I've saved that for you!" // a false claim the engine must not repeat
    func availability() -> AIAvailability { .available }
    func process(_ request: AssistantRequest, actions: AssistantActions) async throws -> ProviderResponse { ProviderResponse(text: reply, clarificationQuestion: nil) }
    func prewarm() async {}
}

@MainActor
enum TestEnv {
    /// Wednesday 2 September 2026, 10:00 New York.
    static var now: Date { Fixture.date(2026, 9, 2, 10, 0) }

    static func make(provider: AIProvider? = UnavailableProvider(), now: Date = TestEnv.now) -> (AppEnvironment, MockNotificationScheduler) {
        let defaults = UserDefaults(suiteName: "DayMindTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.timeZoneIdentifier = "America/New_York"
        settings.transcriptRetention = .forever
        let mock = MockNotificationScheduler()
        let env = AppEnvironment(settings: settings, inMemory: true, cloudKit: false, notifications: mock, provider: provider)
        env.reminders.now = { now }
        env.assistant.now = { now }
        env.briefing.now = { now }
        return (env, mock)
    }
}

enum Fixture {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func components(_ date: Date) -> [Int] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }
}

func XCTAssertDate(_ date: Date?, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, file: StaticString = #filePath, line: UInt = #line) {
    guard let date else { XCTFail("date was nil", file: file, line: line); return }
    XCTAssertEqual(Fixture.components(date), [y, m, d, h, min], file: file, line: line)
}
