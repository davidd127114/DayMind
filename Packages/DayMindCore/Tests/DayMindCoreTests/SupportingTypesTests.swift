import XCTest
@testable import DayMindCore

final class SupportingTypesTests: XCTestCase {
    func testRecurrenceParserPhrases() {
        let p = RecurrenceParser(calendar: Fixture.calendar)
        XCTAssertEqual(p.parse("every day")?.rule, .daily)
        XCTAssertEqual(p.parse("daily at 8 am")?.rule, .daily)
        XCTAssertEqual(p.parse("every weekday")?.rule, .weekdays)
        XCTAssertEqual(p.parse("every other week")?.rule, RecurrenceRule(frequency: .weekly, interval: 2))
        XCTAssertEqual(p.parse("every monday and wednesday")?.rule, RecurrenceRule(frequency: .weekly, weekdays: [2, 4]))
        XCTAssertEqual(p.parse("every month on the 15th")?.rule, RecurrenceRule(frequency: .monthly, dayOfMonth: 15))
        XCTAssertEqual(p.parse("every last friday of the month")?.rule, RecurrenceRule(frequency: .monthly, weekdays: [6], weekOfMonth: -1))
        XCTAssertEqual(p.parse("every evening")?.impliedTime, TimeOfDay(hour: 18))
        XCTAssertEqual(p.parse("every monday morning remind me to take the trash out")?.remainder, "remind me to take the trash out")
        XCTAssertNil(p.parse("tomorrow at 3"))
    }

    func testSpokenFormatter() {
        let cal = Fixture.calendar
        let loc = Locale(identifier: "en_US")
        let target = Fixture.date(2026, 9, 11, 10, 0)
        XCTAssertEqual(SpokenFormatter.dateTimePhrase(target, now: Fixture.now, calendar: cal, locale: loc), "Friday, September 11 at 10:00 AM")
        XCTAssertEqual(SpokenFormatter.dateTimePhrase(Fixture.date(2026, 9, 3, 15, 0), now: Fixture.now, calendar: cal, locale: loc), "tomorrow at 3:00 PM")
        XCTAssertEqual(SpokenFormatter.reminderConfirmation(title: "Call Michael", date: target, recurrence: nil, now: Fixture.now, calendar: cal, locale: loc),
                       "Done. I'll remind you to call Michael Friday, September 11 at 10:00 AM.")
        XCTAssertEqual(SpokenFormatter.durationPhrase(7200), "2 hours")
        XCTAssertEqual(SpokenFormatter.durationPhrase(1800), "30 minutes")
    }

    func testTextMatching() {
        XCTAssertGreaterThan(TextMatching.score(query: "plumber", against: "Plumber comes to fix the sink"), 0.9)
        XCTAssertGreaterThan(TextMatching.score(query: "the call", against: "Call Michael"), 0.9)
        XCTAssertEqual(TextMatching.score(query: "dentist", against: "Pay rent"), 0)
        let ranked = TextMatching.rank(["Call Michael", "Pay rent", "Plumber visit"], query: "plumber", text: { $0 })
        XCTAssertEqual(ranked.first?.item, "Plumber visit")
        XCTAssertEqual(ranked.count, 1)
    }

    func testBriefingComposer() {
        let composer = BriefingComposer(calendar: Fixture.calendar, locale: Locale(identifier: "en_US"))
        let input = BriefingInput(now: Fixture.now,
                                  today: [BriefingItem(title: "Call Michael", dueDate: Fixture.date(2026, 9, 2, 15, 0))],
                                  overdue: [BriefingItem(title: "Pay rent", dueDate: Fixture.date(2026, 9, 1, 9, 0))],
                                  upcoming: [BriefingItem(title: "Plumber", dueDate: Fixture.date(2026, 9, 4, 10, 0), priority: .high)],
                                  inboxCount: 1)
        let text = composer.compose(input)
        XCTAssertTrue(text.contains("Good morning."), text)
        XCTAssertTrue(text.contains("One reminder is overdue: \"Pay rent\"."), text)
        XCTAssertTrue(text.contains("Today: Call Michael at 3:00 PM."), text)
        XCTAssertTrue(text.contains("Coming up: Plumber Friday, September 4."), text)
        XCTAssertTrue(text.contains("One capture in your Inbox still needs review."), text)
        XCTAssertEqual(composer.headline(input), "1 today · 1 overdue")
        XCTAssertEqual(composer.headline(BriefingInput(now: Fixture.now, today: [], overdue: [], upcoming: [], inboxCount: 0)), "Nothing scheduled today")
    }

    func testExportRoundTrip() throws {
        let id = UUID()
        let reminder = ReminderDTO(id: id, title: "Call Michael", notes: "", createdAt: Fixture.now, dueDate: Fixture.date(2026, 9, 3, 15, 0), timeZoneIdentifier: "America/New_York",
                                   recurrence: nil, priority: .normal, status: .pending, completedAt: nil, snoozeHistory: [], missedOccurrences: [], notificationIdentifier: nil,
                                   peopleIDs: [], projectID: nil, relatedMemoryIDs: [], originalTranscript: "remind me tomorrow at 3 pm to call michael", lastModified: Fixture.now, repeatIfIncomplete: false)
        let doc = ExportDocument(exportedAt: Fixture.now, appVersion: "0.1.0", reminders: [reminder], memories: [], people: [], projects: [], inbox: [], conversation: [], preferences: nil)
        let data = try doc.encoded()
        let back = try ExportDocument.decode(data)
        XCTAssertEqual(back.reminders.first?.id, id)
        XCTAssertEqual(back.schemaVersion, 1)
        XCTAssertEqual(back.reminders.first?.dueDate, reminder.dueDate)
    }

    func testExportRejectsNewerSchema() throws {
        var doc = ExportDocument(exportedAt: Fixture.now, appVersion: "9", reminders: [], memories: [], people: [], projects: [], inbox: [], conversation: [], preferences: nil)
        doc.schemaVersion = 99
        let data = try DayMindJSON.encoder().encode(doc)
        XCTAssertThrowsError(try ExportDocument.decode(data))
    }
}
