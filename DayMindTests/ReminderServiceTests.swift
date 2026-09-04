import XCTest
import DayMindCore
@testable import DayMind

@MainActor
final class ReminderServiceTests: XCTestCase {
    var env: AppEnvironment!
    var mock: MockNotificationScheduler!

    override func setUp() async throws {
        (env, mock) = TestEnv.make()
    }

    func testCreateSchedulesNotificationAtDueDate() async throws {
        let due = Fixture.date(2026, 9, 3, 15, 0)
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due, hasExplicitTime: true, people: ["Michael"]), transcript: "remind me tomorrow at 3 pm to call michael")
        XCTAssertEqual(r.notificationIdentifier, "reminder-\(r.id.uuidString)")
        let plan = mock.scheduled["reminder-\(r.id.uuidString)"]
        XCTAssertEqual(plan?.fireDate, due)
        XCTAssertNil(plan?.repeating)
        XCTAssertEqual(r.peopleNames, ["Michael"])
        XCTAssertEqual(r.originalTranscript, "remind me tomorrow at 3 pm to call michael")
        XCTAssertEqual(r.timeZoneIdentifier, "America/New_York")
    }

    func testValidationRejectsEmptyTitleAndFarDates() async {
        do {
            _ = try await env.reminders.create(from: ReminderDraft(title: "   "), transcript: nil)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ReminderServiceError, .emptyTitle) }
        do {
            _ = try await env.reminders.create(from: ReminderDraft(title: "Far", dueDate: Fixture.date(2040, 1, 1)), transcript: nil)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ReminderServiceError, .dateTooFar) }
        do {
            _ = try await env.reminders.create(from: ReminderDraft(title: "Repeat", recurrence: .daily), transcript: nil)
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? ReminderServiceError, .recurrenceNeedsDate) }
    }

    func testDuplicateDetection() async throws {
        let due = Fixture.date(2026, 9, 3, 15, 0)
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due), transcript: nil)
        do {
            _ = try await env.reminders.create(from: ReminderDraft(title: "call michael", dueDate: due.addingTimeInterval(3600)), transcript: nil)
            XCTFail("expected duplicate error")
        } catch ReminderServiceError.possibleDuplicate(_, let title) {
            XCTAssertEqual(title, "Call Michael")
        }
        let second = try await env.reminders.create(from: ReminderDraft(title: "call michael", dueDate: due), transcript: nil, allowDuplicate: true)
        XCTAssertEqual(env.reminders.pending().count, 2)
        XCTAssertNotNil(second)
    }

    func testSnoozeMovesDueDateAndReschedules() async throws {
        let due = Fixture.date(2026, 9, 3, 15, 0)
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due), transcript: nil)
        let newDate = try await env.reminders.snooze(r, by: 7200)
        XCTAssertDate(newDate, 2026, 9, 3, 17, 0)
        XCTAssertEqual(r.snoozeHistory.count, 1)
        XCTAssertEqual(r.snoozeHistory.first?.previousDueDate, due)
        XCTAssertEqual(mock.scheduled["reminder-\(r.id.uuidString)"]?.fireDate, newDate)
    }

    func testSnoozeOverdueReminderIsRelativeToNow() async throws {
        let r = try await env.reminders.create(from: ReminderDraft(title: "Old", dueDate: Fixture.date(2026, 9, 1, 9, 0)), transcript: nil)
        let newDate = try await env.reminders.snooze(r, by: 3600)
        XCTAssertDate(newDate, 2026, 9, 2, 11, 0) // now is 10:00
    }

    func testCompleteNonRecurringRemovesNotification() async throws {
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        let id = r.notificationRequestIdentifier
        XCTAssertNotNil(mock.scheduled[id])
        let next = try await env.reminders.complete(r)
        XCTAssertNil(next)
        XCTAssertEqual(r.status, .completed)
        XCTAssertNotNil(r.completedAt)
        XCTAssertNil(mock.scheduled[id])
        XCTAssertTrue(mock.removed.contains(id))
    }

    func testCompleteRecurringAdvancesToNextOccurrence() async throws {
        let monday = Fixture.date(2026, 9, 7, 9, 0)
        let r = try await env.reminders.create(from: ReminderDraft(title: "Take the trash out", dueDate: monday, hasExplicitTime: true, recurrence: RecurrenceRule(frequency: .weekly, weekdays: [2])), transcript: nil)
        let plan = mock.scheduled[r.notificationRequestIdentifier]
        XCTAssertEqual(plan?.repeating?.weekday, 2, "simple weekly rule uses a repeating trigger")
        let next = try await env.reminders.complete(r)
        XCTAssertDate(next, 2026, 9, 14, 9, 0)
        XCTAssertEqual(r.status, .pending)
        XCTAssertDate(r.dueDate, 2026, 9, 14, 9, 0)
    }

    func testFirstMondayRuleSchedulesSingleOccurrences() async throws {
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1)
        let firstMonday = Fixture.date(2026, 9, 7, 9, 0)
        let r = try await env.reminders.create(from: ReminderDraft(title: "Pay rent", dueDate: firstMonday, hasExplicitTime: true, recurrence: rule), transcript: nil)
        let plan = mock.scheduled[r.notificationRequestIdentifier]
        XCTAssertNil(plan?.repeating)
        XCTAssertEqual(plan?.fireDate, firstMonday)
        let next = try await env.reminders.complete(r)
        XCTAssertDate(next, 2026, 10, 5, 9, 0)
        XCTAssertEqual(mock.scheduled[r.notificationRequestIdentifier]?.fireDate, next)
    }

    func testRollForwardRecordsMissedOccurrences() async throws {
        // Weekly Monday reminder anchored two weeks ago and never completed.
        let past = Fixture.date(2026, 8, 17, 9, 0) // Monday
        let r = try await env.reminders.create(from: ReminderDraft(title: "Water plants", dueDate: past, hasExplicitTime: true, recurrence: RecurrenceRule(frequency: .weekly, weekdays: [2])), transcript: nil)
        await env.reminders.rollForwardRecurring()
        // Occurrences: Aug 17 (missed), Aug 24 (missed), Aug 31 (missed, current overdue) → next Sep 7 is in the future, so due stays Aug 31.
        XCTAssertDate(r.dueDate, 2026, 8, 31, 9, 0)
        XCTAssertEqual(r.missedOccurrences.count, 2)
        XCTAssertTrue(r.isOverdue(now: TestEnv.now))
        let forgottenYesterday = env.reminders.forgotten(on: Fixture.date(2026, 9, 1))
        XCTAssertTrue(forgottenYesterday.isEmpty)
    }

    func testForgottenYesterday() async throws {
        let r = try await env.reminders.create(from: ReminderDraft(title: "Renew registration", dueDate: Fixture.date(2026, 9, 1, 9, 0)), transcript: nil)
        let list = env.reminders.list(scope: .forgottenYesterday)
        XCTAssertEqual(list.map(\.id), [r.id])
        XCTAssertEqual(env.reminders.list(scope: .overdue).count, 1)
    }

    func testDeleteRemovesNotificationsAndDeleteAll() async throws {
        let a = try await env.reminders.create(from: ReminderDraft(title: "A", dueDate: Fixture.date(2026, 9, 3, 9, 0)), transcript: nil)
        let b = try await env.reminders.create(from: ReminderDraft(title: "B", dueDate: Fixture.date(2026, 9, 4, 9, 0)), transcript: nil)
        let idA = a.notificationRequestIdentifier
        try await env.reminders.delete(a)
        XCTAssertNil(mock.scheduled[idA])
        XCTAssertEqual(env.reminders.fetchAll().count, 1)
        let count = try await env.reminders.deleteAll()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertNil(mock.scheduled[b.notificationRequestIdentifier])
    }

    func testFollowUpSchedulesSecondNotification() async throws {
        let r = try await env.reminders.create(from: ReminderDraft(title: "Submit form", dueDate: Fixture.date(2026, 9, 3, 9, 0)), transcript: nil)
        let followUp = Fixture.date(2026, 9, 4, 9, 0)
        try await env.reminders.setFollowUp(r, at: followUp)
        XCTAssertEqual(mock.scheduled[r.followUpNotificationIdentifier]?.fireDate, followUp)
        _ = try await env.reminders.complete(r)
        XCTAssertNil(mock.scheduled[r.followUpNotificationIdentifier])
    }

    func testReconcileRepairsMissingAndRemovesOrphans() async throws {
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        // Simulate iOS having lost the request, plus a stale orphan from a deleted reminder.
        mock.scheduled.removeAll()
        mock.scheduled["reminder-ORPHAN"] = NotificationPlan(identifier: "reminder-ORPHAN", title: "x", body: "", fireDate: Fixture.date(2026, 9, 9), repeating: nil, reminderID: UUID())
        await env.reminders.reconcileNotifications()
        XCTAssertNotNil(mock.scheduled[r.notificationRequestIdentifier])
        XCTAssertNil(mock.scheduled["reminder-ORPHAN"])
    }

    func testFindByReferenceWithDayHintAndTitle() async throws {
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: Fixture.date(2026, 9, 3, 15, 0)), transcript: nil)
        _ = try await env.reminders.create(from: ReminderDraft(title: "Call the bank", dueDate: Fixture.date(2026, 9, 4, 15, 0)), transcript: nil)
        let byDay = env.reminders.find(reference: ReminderReference(titleHint: "call", dayHint: Fixture.date(2026, 9, 3)), focusID: nil)
        XCTAssertEqual(byDay.map(\.title), ["Call Michael"])
        let ambiguous = env.reminders.find(reference: ReminderReference(titleHint: "call"), focusID: nil)
        XCTAssertEqual(ambiguous.count, 2)
        XCTAssertTrue(env.reminders.find(reference: ReminderReference(titleHint: "dentist"), focusID: nil).isEmpty)
    }

    func testTimeZoneChangeKeepsInstantButChangesWording() async throws {
        let due = Fixture.date(2026, 9, 3, 15, 0) // 3 PM New York
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due), transcript: nil)
        env.settings.timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertEqual(r.dueDate, due, "the stored instant never changes")
        let tokyo = env.settings.calendar
        XCTAssertEqual(tokyo.component(.hour, from: r.dueDate!), 4, "3 PM New York is 4 AM the next day in Tokyo")
        XCTAssertEqual(tokyo.component(.day, from: r.dueDate!), 4)
    }

    func testNotificationPlannerDailyRuleAndPastDates() throws {
        let r = Reminder(title: "Daily", dueDate: Fixture.date(2026, 9, 2, 8, 0), recurrence: .daily)
        let plans = NotificationPlanner.plans(for: r, calendar: Fixture.calendar, now: TestEnv.now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.repeating?.hour, 8)
        XCTAssertNil(plans.first?.repeating?.weekday)
        let done = Reminder(title: "Done", dueDate: Fixture.date(2026, 9, 5, 8, 0))
        done.status = .completed
        XCTAssertTrue(NotificationPlanner.plans(for: done, calendar: Fixture.calendar, now: TestEnv.now).isEmpty)
    }
}
