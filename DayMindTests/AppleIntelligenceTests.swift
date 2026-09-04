import XCTest
import DayMindCore
@testable import DayMind

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability handling is tested everywhere; the live model is exercised only when the test
/// device/simulator actually has Apple Intelligence available. Otherwise those tests are skipped
/// and reported as skipped — never as passing.
@MainActor
final class AppleIntelligenceTests: XCTestCase {
    func testUnavailableReasonsMapToActionableMessages() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires iOS 26") }
        let notEligible = AppleIntelligenceProvider.map(.deviceNotEligible)
        guard case .unavailable(let reason, _, let retry) = notEligible else { return XCTFail() }
        XCTAssertTrue(reason.contains("does not support Apple Intelligence"))
        XCTAssertFalse(retry)

        let off = AppleIntelligenceProvider.map(.appleIntelligenceNotEnabled)
        guard case .unavailable(_, let suggestion, let retry2) = off else { return XCTFail() }
        XCTAssertTrue(suggestion?.contains("Settings") == true)
        XCTAssertTrue(retry2)

        let downloading = AppleIntelligenceProvider.map(.modelNotReady)
        guard case .unavailable(let reason3, _, let retry3) = downloading else { return XCTFail() }
        XCTAssertTrue(reason3.contains("downloading"))
        XCTAssertTrue(retry3)
        #else
        throw XCTSkip("FoundationModels not available in this SDK")
        #endif
    }

    func testGenerationErrorsMapToInboxReasons() {
        XCTAssertEqual(AIProcessingError.modelUnavailable("x").inboxReason, .modelUnavailable)
        XCTAssertEqual(AIProcessingError.inputTooLong.inboxReason, .modelFailed)
        XCTAssertEqual(AIProcessingError.blockedBySafetyFilter.inboxReason, .modelFailed)
        XCTAssertEqual(AIProcessingError.busy.inboxReason, .modelFailed)
    }

    func testDefaultProviderIsAppleOnDeviceOnly() {
        let provider = AppEnvironment.defaultProvider()
        #if canImport(FoundationModels)
        XCTAssertEqual(provider?.id, "apple.foundation-models")
        XCTAssertTrue(provider?.costAndPrivacyNote.contains("Free") == true)
        #else
        XCTAssertNil(provider)
        #endif
    }

    func testEngineReportsRealAvailabilityOfThisMachine() {
        let (env, _) = TestEnv.make(provider: AppEnvironment.defaultProvider())
        let availability = env.assistant.lastAvailability
        // Whatever the answer is, it must be explained.
        XCTAssertFalse(availability.detail.isEmpty)
        print("Apple Intelligence on this test host: \(availability.title) — \(availability.detail)")
    }

    /// Runs the first acceptance statement through the real on-device model when it is available.
    func testLiveModelCreatesReminderFromNaturalSpeech() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires iOS 26") }
        guard SystemLanguageModel.default.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this test host: \(AppleIntelligenceProvider().availability().detail)")
        }
        let (env, _) = TestEnv.make(provider: AppleIntelligenceProvider(), now: Date())
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        XCTAssertEqual(r.mode, .appleIntelligence)
        let pending = env.reminders.pending()
        XCTAssertEqual(pending.count, 1, r.responseText)
        XCTAssertTrue(pending.first?.title.localizedCaseInsensitiveContains("Michael") == true)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(Calendar.current.isDate(pending.first!.dueDate!, inSameDayAs: tomorrow))
        XCTAssertEqual(Calendar.current.component(.hour, from: pending.first!.dueDate!), 15)

        let m = await env.assistant.handle("Remember that Michael prefers afternoon appointments.", source: .text)
        XCTAssertEqual(env.memories.fetchAll().count, 1, m.responseText)

        let q = await env.assistant.handle("What did I tell you about Michael?", source: .text)
        XCTAssertTrue(q.responseText.localizedCaseInsensitiveContains("afternoon"), q.responseText)

        let d = await env.assistant.handle("Delete all of my reminders.", source: .text)
        XCTAssertNotNil(d.pending, "bulk deletion must always wait for confirmation")
        XCTAssertEqual(env.reminders.pending().count, 1)
        #else
        throw XCTSkip("FoundationModels not available in this SDK")
        #endif
    }
}
