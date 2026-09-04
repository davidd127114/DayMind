import XCTest
import DayMindCore
@testable import DayMind

/// The nine acceptance statements run end-to-end through the engine, the actions layer and the
/// database — in deterministic mode (Apple Intelligence unavailable), which is the guaranteed path.
@MainActor
final class AssistantEngineAcceptanceTests: XCTestCase {
    var env: AppEnvironment!
    var mock: MockNotificationScheduler!

    override func setUp() async throws {
        (env, mock) = TestEnv.make()
    }

    func testAcceptanceScriptInOrder() async throws {
        // 1
        var r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        XCTAssertEqual(r.mode, .deterministic)
        XCTAssertTrue(r.responseText.contains("tomorrow at 3:00 PM"), r.responseText)
        XCTAssertEqual(env.reminders.pending().count, 1)
        let call = env.reminders.pending()[0]
        XCTAssertEqual(call.title, "Call Michael")
        XCTAssertDate(call.dueDate, 2026, 9, 3, 15, 0)
        XCTAssertEqual(call.peopleNames, ["Michael"])
        XCTAssertNotNil(mock.scheduled[call.notificationRequestIdentifier])

        // 2
        r = await env.assistant.handle("Every first Monday of the month at 9 AM, remind me to pay rent.", source: .text)
        XCTAssertTrue(r.responseText.contains("the first Monday of every month at 9:00 AM"), r.responseText)
        let rent = env.reminders.pending().first { $0.title == "Pay rent" }
        XCTAssertNotNil(rent)
        XCTAssertDate(rent?.dueDate, 2026, 9, 7, 9, 0)
        XCTAssertEqual(rent?.recurrence, RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1))

        // 3
        r = await env.assistant.handle("Remember that Michael prefers afternoon appointments.", source: .text)
        XCTAssertTrue(r.responseText.hasPrefix("Got it. I'll remember that"), r.responseText)
        let memories = env.memories.fetchAll()
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].category, .preference)
        XCTAssertEqual(memories[0].peopleNames, ["Michael"])

        // 4
        r = await env.assistant.handle("What did I tell you about Michael?", source: .text)
        XCTAssertTrue(r.responseText.contains("Michael prefers afternoon appointments"), r.responseText)
        XCTAssertEqual(env.memories.fetchAll().count, 1, "a question must not create data")

        // 5
        r = await env.assistant.handle("Change tomorrow's call to Friday at 10.", source: .text)
        XCTAssertTrue(r.responseText.contains("Friday, September 4 at 10:00 AM"), r.responseText)
        XCTAssertDate(call.dueDate, 2026, 9, 4, 10, 0)
        XCTAssertEqual(mock.scheduled[call.notificationRequestIdentifier]?.fireDate, call.dueDate)

        // 6 — "that" refers to the reminder just changed
        r = await env.assistant.handle("Snooze that for two hours.", source: .text)
        XCTAssertTrue(r.responseText.contains("Snoozed “Call Michael” until Friday, September 4 at 12:00 PM"), r.responseText)
        XCTAssertDate(call.dueDate, 2026, 9, 4, 12, 0)
        XCTAssertEqual(call.snoozeHistory.count, 1)

        // 7
        r = await env.assistant.handle("What am I forgetting today?", source: .text)
        XCTAssertTrue(r.responseText.contains("Nothing is due today"), r.responseText)
        XCTAssertEqual(env.reminders.pending().count, 2)

        // 8 — "this" = most recently touched item (the call reminder)
        r = await env.assistant.handle("Save this under the kitchen renovation project.", source: .text)
        XCTAssertTrue(r.responseText.contains("Filed “Call Michael” under Kitchen Renovation"), r.responseText)
        XCTAssertEqual(call.project?.name, "Kitchen Renovation")
        XCTAssertEqual(env.projects.all().count, 1)

        // 9 — must require explicit confirmation
        r = await env.assistant.handle("Delete all of my reminders.", source: .text)
        XCTAssertEqual(r.pending, .deleteAllReminders(count: 2))
        XCTAssertTrue(r.responseText.contains("Delete all 2 reminders?"), r.responseText)
        XCTAssertEqual(env.reminders.fetchAll().count, 2, "nothing is deleted before confirmation")
        XCTAssertFalse(r.actions.contains { $0.changedData })

        r = await env.assistant.handle("no", source: .text)
        XCTAssertEqual(env.reminders.fetchAll().count, 2)
        XCTAssertNil(env.assistant.pendingAction)

        r = await env.assistant.handle("Delete all of my reminders.", source: .text)
        r = await env.assistant.handle("yes", source: .text)
        XCTAssertTrue(r.responseText.contains("Deleted 2 reminders"), r.responseText)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertTrue(mock.scheduled.isEmpty)
    }

    func testMixedSentenceSavesMemoryAndReminder() async {
        let r = await env.assistant.handle("John prefers text messages, so remind me tomorrow to message him", source: .voice)
        XCTAssertEqual(env.memories.fetchAll().count, 1)
        XCTAssertEqual(env.reminders.pending().count, 1)
        XCTAssertEqual(env.reminders.pending().first?.title, "Message John")
        XCTAssertTrue(r.responseText.contains("Got it. I'll remember that"), r.responseText)
        XCTAssertTrue(r.responseText.contains("Done. I'll remind you to message John tomorrow"), r.responseText)
    }

    func testAmbiguousTimeAsksOneQuestionAndSavesNothing() async {
        let r = await env.assistant.handle("Remind me later to call the bank", source: .text)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertNotNil(r.suggestedReminder)
        XCTAssertEqual(r.suggestedReminder?.title, "Call the bank")
        XCTAssertTrue(r.responseText.contains("When should I remind you?"), r.responseText)
    }

    func testUnknownInputGoesToInboxWhenModelUnavailable() async {
        let r = await env.assistant.handle("purple elephants dancing", source: .voice)
        XCTAssertEqual(env.inbox.unresolved().count, 1)
        XCTAssertEqual(env.inbox.unresolved().first?.reason, .modelUnavailable)
        XCTAssertEqual(env.inbox.unresolved().first?.source, .voice)
        XCTAssertNotNil(r.inboxItemID)
        XCTAssertTrue(r.responseText.contains("Apple Intelligence is turned off."), r.responseText)
        XCTAssertTrue(r.responseText.contains("Inbox"), r.responseText)

        // Retry while still unavailable keeps the item and counts the attempt.
        let item = env.inbox.unresolved()[0]
        _ = await env.assistant.retry(item)
        XCTAssertEqual(env.inbox.unresolved().count, 1)
        XCTAssertEqual(item.retryCount, 1)
    }

    func testDisambiguationWhenSeveralRemindersMatch() async throws {
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        let bank = try await env.reminders.create(from: ReminderDraft(title: "Call the bank", dueDate: Fixture.date(2026, 9, 4, 15, 0)), transcript: nil)
        env.actions.focusReminderID = nil
        let r = await env.assistant.handle("Mark the call reminder as done", source: .text)
        guard case .chooseReminder(let candidates, .complete)? = r.pending else { return XCTFail("expected a choice, got \(String(describing: r.pending))") }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(env.reminders.pending().count, 2, "nothing changes until the user chooses")
        let chosen = await env.assistant.choose(reminderID: bank.id)
        XCTAssertTrue(chosen.responseText.contains("Marked “Call the bank” as done"), chosen.responseText)
        XCTAssertEqual(bank.status, .completed)
    }

    func testDuplicateAsksBeforeAddingAgain() async throws {
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        let r = await env.assistant.handle("Remind me tomorrow at 4 PM to call Michael", source: .text)
        guard case .createReminderDespiteDuplicate? = r.pending else { return XCTFail("expected duplicate confirmation") }
        XCTAssertEqual(env.reminders.pending().count, 1)
        let confirmed = await env.assistant.confirmPending()
        XCTAssertTrue(confirmed.responseText.contains("Done."), confirmed.responseText)
        XCTAssertEqual(env.reminders.pending().count, 2)
    }

    func testFollowUpIfNotCompleted() async throws {
        let r0 = await env.assistant.handle("Remind me today at 6 PM to submit the form", source: .text)
        XCTAssertTrue(r0.actions.contains { $0.changedData })
        let r = await env.assistant.handle("Remind me again tomorrow if I don't complete this.", source: .text)
        let reminder = env.reminders.pending()[0]
        XCTAssertDate(reminder.followUpDate, 2026, 9, 3, 9, 0)
        XCTAssertNotNil(mock.scheduled[reminder.followUpNotificationIdentifier])
        XCTAssertTrue(r.responseText.contains("I'll remind you again tomorrow at 9:00 AM"), r.responseText)
    }

    func testBriefingAndForgottenYesterday() async throws {
        _ = try await env.reminders.create(from: ReminderDraft(title: "Renew registration", dueDate: Fixture.date(2026, 9, 1, 9, 0)), transcript: nil)
        var r = await env.assistant.handle("What tasks did I forget yesterday?", source: .text)
        XCTAssertTrue(r.responseText.contains("Yesterday you missed one thing: Renew registration"), r.responseText)
        r = await env.assistant.handle("Give me my daily briefing", source: .text)
        XCTAssertTrue(r.responseText.contains("One reminder is overdue"), r.responseText)
    }

    func testDoctorsOfficeIsSavedAsMemoryNotReminder() async {
        _ = await env.assistant.handle("Remember that my doctor's office is closed on Fridays.", source: .text)
        XCTAssertEqual(env.memories.fetchAll().count, 1)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
    }

    func testConversationTurnsAreLoggedAndPurgedByRetention() async {
        _ = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        XCTAssertEqual(env.conversation.recent().count, 2)
        env.settings.transcriptRetention = .never
        env.conversation.purgeExpired()
        XCTAssertTrue(env.conversation.recent().isEmpty)
        XCTAssertNil(env.reminders.pending().first?.originalTranscript)
    }
}

/// Model-failure paths: the engine must never lose input or repeat a false claim from the model.
@MainActor
final class AssistantEngineFailureTests: XCTestCase {
    func testModelFailureFallsBackToRulesForClearRequests() async {
        let (env, _) = TestEnv.make(provider: FailingProvider())
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .voice)
        XCTAssertEqual(env.reminders.pending().count, 1)
        XCTAssertTrue(r.responseText.contains("tomorrow at 3:00 PM"), r.responseText)
        XCTAssertTrue(r.responseText.contains("snag"), "explains that the rules path was used: \(r.responseText)")
    }

    func testModelFailureKeepsUnclearRequestsInInbox() async {
        let (env, _) = TestEnv.make(provider: FailingProvider())
        let r = await env.assistant.handle("the thing we discussed about the stuff", source: .voice)
        XCTAssertEqual(env.inbox.unresolved().count, 1)
        XCTAssertEqual(env.inbox.unresolved().first?.reason, .modelFailed)
        XCTAssertNotNil(r.inboxItemID)
    }

    func testProseOnlyModelReplyNeverBecomesAFalseConfirmation() async {
        let (env, _) = TestEnv.make(provider: ChattyProvider())
        // The fake model claims "I've saved that" without calling any tool. The engine must act
        // deterministically instead (clear request) …
        var r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        XCTAssertEqual(env.reminders.pending().count, 1)
        XCTAssertFalse(r.responseText.contains("Sure, I've saved that"), r.responseText)
        // … and for a non-command it may use the model's words, because nothing was claimed to change.
        r = await env.assistant.handle("how are you doing", source: .text)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(env.reminders.pending().count, 1)
    }

    func testInterruptedListeningPreservesTranscript() {
        let (env, _) = TestEnv.make()
        env.voice.onInterrupted = { text in
            env.inbox.add(text: text, source: .voice, reason: .speechFailed, detail: "interrupted")
        }
        env.voice.onInterrupted?("remind me to call the plumber tomorrow at")
        XCTAssertEqual(env.inbox.unresolved().count, 1)
        XCTAssertEqual(env.inbox.unresolved().first?.reason, .speechFailed)
    }
}
