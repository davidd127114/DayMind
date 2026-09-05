import XCTest
import SwiftData
import DayMindCore
@testable import DayMind

/// Truthful states and genuine undo — the butler must never claim more than actually happened.
@MainActor
final class ReliabilityTests: XCTestCase {
    func testScheduledStateWhenNotificationsAllowed() async {
        let (env, mock) = TestEnv.make()
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        guard case .reminderCreated(let summary)? = r.actions.first?.kind else { return XCTFail("no created record") }
        XCTAssertEqual(summary.scheduleStatus, .scheduled)
        XCTAssertEqual(r.responseText, "Certainly. Call Michael — tomorrow at 3:00 PM.")
        XCTAssertEqual(mock.scheduled.count, 1)
    }

    func testSavedButNotificationsDeniedIsSaidPlainly() async {
        let (env, mock) = TestEnv.make()
        mock.authorized = false
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        guard case .reminderCreated(let summary)? = r.actions.first?.kind else { return XCTFail("no created record") }
        XCTAssertEqual(summary.scheduleStatus, .notificationsDenied)
        XCTAssertEqual(env.reminders.pending().count, 1, "the reminder itself is still saved")
        XCTAssertTrue(r.responseText.contains("notifications are turned off"), r.responseText)
        XCTAssertFalse(r.responseText.contains("I'll remind you"), "must not promise an alert it cannot deliver")
    }

    func testSavedButSchedulingFailedIsSaidPlainly() async {
        let (env, mock) = TestEnv.make()
        mock.failAll = true
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        guard case .reminderCreated(let summary)? = r.actions.first?.kind else { return XCTFail("no created record") }
        XCTAssertEqual(summary.scheduleStatus, .failed("simulated scheduling failure"))
        XCTAssertEqual(env.reminders.pending().count, 1)
        XCTAssertTrue(r.responseText.contains("could not schedule the alert"), r.responseText)
    }

    func testRepeatingRuleReportsRepeatingAlert() async {
        let (env, _) = TestEnv.make()
        let r = await env.assistant.handle("Every Monday morning, remind me to take the trash out.", source: .text)
        guard case .reminderCreated(let summary)? = r.actions.first?.kind else { return XCTFail() }
        XCTAssertEqual(summary.scheduleStatus, .repeating)
        XCTAssertTrue(r.responseText.contains("Repeats every Monday at 9:00 AM"), r.responseText)
    }

    func testUndoCreateDeletesReminderAndAlert() async {
        let (env, mock) = TestEnv.make()
        let r = await env.assistant.handle("Remind me tomorrow at 3 PM to call Michael.", source: .text)
        let record = r.actions[0]
        XCTAssertTrue(env.assistant.canUndo(record))
        let undone = await env.assistant.undo(record)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertTrue(mock.scheduled.isEmpty)
        XCTAssertTrue(undone.responseText.hasPrefix("Undone."), undone.responseText)
        XCTAssertFalse(env.assistant.canUndo(record), "undo is one-shot")
    }

    func testUndoCompleteReopens() async throws {
        let (env, mock) = TestEnv.make()
        let reminder = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        let r = await env.assistant.complete(reminderID: reminder.id)
        XCTAssertEqual(reminder.status, .completed)
        XCTAssertNil(mock.scheduled[reminder.notificationRequestIdentifier])
        _ = await env.assistant.undo(r.actions[0])
        XCTAssertEqual(reminder.status, .pending)
        XCTAssertNil(reminder.completedAt)
        XCTAssertNotNil(mock.scheduled[reminder.notificationRequestIdentifier], "alert is rescheduled when reopened")
    }

    func testUndoSnoozeRestoresTimeAndHistory() async throws {
        let (env, mock) = TestEnv.make()
        let due = Fixture.date(2026, 9, 3, 15, 0)
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due), transcript: nil)
        env.actions.focusReminderID = env.reminders.pending()[0].id
        let r = await env.assistant.handle("Snooze that for two hours.", source: .text)
        let reminder = env.reminders.pending()[0]
        XCTAssertDate(reminder.dueDate, 2026, 9, 3, 17, 0)
        XCTAssertEqual(reminder.snoozeHistory.count, 1)
        _ = await env.assistant.undo(r.actions[0])
        XCTAssertEqual(reminder.dueDate, due)
        XCTAssertEqual(reminder.snoozeHistory.count, 0)
        XCTAssertEqual(mock.scheduled[reminder.notificationRequestIdentifier]?.fireDate, due)
    }

    func testUndoDeleteRestoresSameReminder() async throws {
        let (env, mock) = TestEnv.make()
        let reminder = try await env.reminders.create(from: ReminderDraft(title: "Plumber visit", notes: "Ask about the drain", dueDate: Fixture.date(2026, 9, 3, 10, 0), people: ["Michael"], projectName: "Kitchen"), transcript: "words")
        let id = reminder.id
        let r = await env.assistant.handle("Delete the plumber reminder", source: .text)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertNil(mock.scheduled["reminder-\(id.uuidString)"])
        _ = await env.assistant.undo(r.actions[0])
        let restored = env.reminders.fetch(id: id)
        XCTAssertEqual(restored?.title, "Plumber visit")
        XCTAssertEqual(restored?.notes, "Ask about the drain")
        XCTAssertEqual(restored?.peopleNames, ["Michael"])
        XCTAssertEqual(restored?.project?.name, "Kitchen")
        XCTAssertEqual(restored?.originalTranscript, "words")
        XCTAssertNotNil(mock.scheduled["reminder-\(id.uuidString)"])
    }

    func testUndoRememberForgetsAgain() async {
        let (env, _) = TestEnv.make()
        let r = await env.assistant.handle("Remember that Michael prefers afternoon appointments.", source: .text)
        XCTAssertEqual(env.memories.fetchAll().count, 1)
        XCTAssertTrue(env.assistant.canUndo(r.actions[0]))
        _ = await env.assistant.undo(r.actions[0])
        XCTAssertTrue(env.memories.fetchAll(includeArchived: true).isEmpty)
    }

    func testNoUndoOfferedForQuestions() async {
        let (env, _) = TestEnv.make()
        let r = await env.assistant.handle("What am I forgetting today?", source: .text)
        XCTAssertFalse(r.actions.isEmpty)
        XCTAssertFalse(env.assistant.canUndo(r.actions[0]))
    }

    func testButlerWordingForMemoryAndSearch() async {
        let (env, _) = TestEnv.make()
        var r = await env.assistant.handle("Remember that John prefers text messages.", source: .text)
        XCTAssertEqual(r.responseText, "Noted. John prefers text messages.")
        r = await env.assistant.handle("What did I tell you about Sarah?", source: .text)
        XCTAssertEqual(r.responseText, "I have nothing saved about sarah.")
    }

    func testEditingCancelsObsoleteAlert() async throws {
        let (env, mock) = TestEnv.make()
        let reminder = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        let id = reminder.notificationRequestIdentifier
        XCTAssertEqual(mock.scheduled[id]?.fireDate, Fixture.date(2026, 9, 3, 15, 0))
        try await env.reminders.apply(ReminderChanges(dueDate: .some(Fixture.date(2026, 9, 4, 10, 0))), to: reminder)
        XCTAssertEqual(mock.scheduled[id]?.fireDate, Fixture.date(2026, 9, 4, 10, 0), "old alert replaced, not duplicated")
        XCTAssertEqual(mock.scheduled.count, 1)
        try await env.reminders.apply(ReminderChanges(dueDate: .some(nil)), to: reminder)
        XCTAssertNil(mock.scheduled[id], "removing the date cancels the alert")
    }

    func testMemoriesSurviveRelaunchOfTheStore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayMindPersist-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema(versionedSchema: DayMindSchemaV1.self)
        let config = ModelConfiguration("Persist", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        let first = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [config])
        let ctx = ModelContext(first)
        ctx.insert(Memory(title: "Doctor hours", content: "The doctor's office is closed on Fridays."))
        try ctx.save()
        let second = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [config])
        let found = try ModelContext(second).fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(found.map(\.content), ["The doctor's office is closed on Fridays."])
    }
}
