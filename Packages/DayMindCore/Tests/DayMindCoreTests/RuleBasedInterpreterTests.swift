import XCTest
@testable import DayMindCore

/// The nine acceptance statements from the specification, interpreted by the deterministic
/// (no-AI) path. The on-device model path is exercised separately in the app tests.
final class RuleBasedInterpreterTests: XCTestCase {
    let i = Fixture.interpreter

    func testAcceptance1_RemindTomorrowAtThree() throws {
        guard case .createReminder(let d) = i.interpret("Remind me tomorrow at 3 PM to call Michael.") else { return XCTFail() }
        XCTAssertEqual(d.title, "Call Michael")
        XCTAssertDate(d.dueDate, 2026, 9, 3, 15, 0)
        XCTAssertEqual(d.people, ["Michael"])
        XCTAssertNil(d.recurrence)
        XCTAssertNil(d.clarificationQuestion)
    }

    func testAcceptance2_FirstMondayRent() throws {
        guard case .createReminder(let d) = i.interpret("Every first Monday of the month at 9 AM, remind me to pay rent.") else { return XCTFail() }
        XCTAssertEqual(d.title, "Pay rent")
        XCTAssertEqual(d.recurrence, RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1))
        XCTAssertDate(d.dueDate, 2026, 9, 7, 9, 0) // first Monday of September 2026
    }

    func testAcceptance3_RememberPreference() throws {
        guard case .saveMemory(let m) = i.interpret("Remember that Michael prefers afternoon appointments.") else { return XCTFail() }
        XCTAssertEqual(m.category, .preference)
        XCTAssertEqual(m.people, ["Michael"])
        XCTAssertEqual(m.content, "Michael prefers afternoon appointments")
    }

    func testAcceptance4_WhatDidITellYou() throws {
        guard case .searchMemories(let q) = i.interpret("What did I tell you about Michael?") else { return XCTFail() }
        XCTAssertEqual(q, "michael")
    }

    func testAcceptance5_ChangeTomorrowsCall() throws {
        guard case .rescheduleReminder(let ref, let date, _) = i.interpret("Change tomorrow's call to Friday at 10.") else { return XCTFail() }
        XCTAssertEqual(ref.titleHint, "call")
        XCTAssertDate(ref.dayHint, 2026, 9, 3, 9, 0)
        XCTAssertDate(date, 2026, 9, 4, 10, 0)
    }

    func testAcceptance6_SnoozeTwoHours() throws {
        guard case .snoozeReminder(let ref, let duration) = i.interpret("Snooze that for two hours.") else { return XCTFail() }
        XCTAssertTrue(ref.usesAnaphora)
        XCTAssertEqual(duration, 7200)
    }

    func testAcceptance7_WhatAmIForgetting() throws {
        guard case .listReminders(let scope) = i.interpret("What am I forgetting today?") else { return XCTFail() }
        XCTAssertEqual(scope, .today)
    }

    func testAcceptance8_SaveUnderProject() throws {
        guard case .assignToProject(let name) = i.interpret("Save this under the kitchen renovation project.") else { return XCTFail() }
        XCTAssertEqual(name, "Kitchen Renovation")
        guard case .assignToProject(let name2) = i.interpret("Save this idea under the kitchen renovation project.") else { return XCTFail() }
        XCTAssertEqual(name2, "Kitchen Renovation")
    }

    func testAcceptance9_DeleteAllRequiresConfirmation() throws {
        XCTAssertEqual(i.interpret("Delete all of my reminders."), .deleteAllReminders)
        XCTAssertEqual(i.interpret("clear all reminders"), .deleteAllReminders)
    }

    // MARK: Additional examples from the brief

    func testEveryMondayMorningTrash() throws {
        guard case .createReminder(let d) = i.interpret("Every Monday morning, remind me to take the trash out.") else { return XCTFail() }
        XCTAssertEqual(d.title, "Take the trash out")
        XCTAssertEqual(d.recurrence, RecurrenceRule(frequency: .weekly, weekdays: [2]))
        XCTAssertDate(d.dueDate, 2026, 9, 7, 9, 0)
    }

    func testMixedPreferenceAndReminder() throws {
        guard case .createReminderAndMemory(let r, let m) = i.interpret("John prefers texts, so remind me tomorrow to message him") else { return XCTFail() }
        XCTAssertEqual(m.people, ["John"])
        XCTAssertEqual(m.category, .preference)
        XCTAssertEqual(r.title, "Message John")
        XCTAssertDate(r.dueDate, 2026, 9, 3, 9, 0)
    }

    func testPeopleExtractionIgnoresCommonNouns() throws {
        XCTAssertEqual(RuleBasedInterpreter.extractPeople(from: "john prefers text messages"), ["John"])
        XCTAssertEqual(RuleBasedInterpreter.extractPeople(from: "text john and mary about the party"), ["John", "Mary"])
        XCTAssertEqual(RuleBasedInterpreter.extractPeople(from: "call the bank"), [])
        XCTAssertEqual(RuleBasedInterpreter.extractPeople(from: "email michael"), ["Michael"])
        guard case .createReminderAndMemory(let r, let m) = i.interpret("John prefers text messages, so remind me tomorrow to message him") else { return XCTFail() }
        XCTAssertEqual(m.people, ["John"])
        XCTAssertEqual(r.title, "Message John")
    }

    func testDoctorsOfficeIsAMemoryNotAReminder() throws {
        guard case .saveMemory(let m) = i.interpret("Remember that my doctor's office is closed on Fridays.") else { return XCTFail() }
        XCTAssertEqual(m.content, "My doctor's office is closed on fridays")
        XCTAssertEqual(m.category, .place)
        XCTAssertEqual(m.people, [])
    }

    func testMovePlumber() throws {
        guard case .rescheduleReminder(let ref, let date, _) = i.interpret("Move tomorrow's plumber reminder to Friday at 10.") else { return XCTFail() }
        XCTAssertEqual(ref.titleHint, "plumber")
        XCTAssertDate(date, 2026, 9, 4, 10, 0)
    }

    func testTodayAndYesterdayQueries() {
        XCTAssertEqual(i.interpret("What do I need to do today?"), .listReminders(.today))
        XCTAssertEqual(i.interpret("What tasks did I forget yesterday?"), .listReminders(.forgottenYesterday))
        XCTAssertEqual(i.interpret("What's coming up this week?"), .listReminders(.upcoming))
    }

    func testFollowUpIfIncomplete() throws {
        guard case .followUpReminder(let ref, let date) = i.interpret("Remind me again tomorrow if I don't complete this.") else { return XCTFail() }
        XCTAssertTrue(ref.usesAnaphora)
        XCTAssertDate(date, 2026, 9, 3, 9, 0)
    }

    func testLaterNeedsClarification() throws {
        guard case .createReminder(let d) = i.interpret("Remind me later to call the bank") else { return XCTFail() }
        XCTAssertNil(d.dueDate)
        XCTAssertNotNil(d.clarificationQuestion)
        XCTAssertEqual(d.title, "Call the bank")
    }

    func testCompleteAndDelete() {
        guard case .completeReminder(let ref) = i.interpret("Mark the plumber reminder as done") else { return XCTFail() }
        XCTAssertEqual(ref.titleHint, "plumber")
        guard case .deleteReminder(let ref2) = i.interpret("Delete the dentist reminder") else { return XCTFail() }
        XCTAssertEqual(ref2.titleHint, "dentist")
    }

    func testChatterIsUnknown() {
        XCTAssertEqual(i.interpret("hello there"), .unknown)
        XCTAssertEqual(i.interpret("thanks"), .unknown)
    }
}
