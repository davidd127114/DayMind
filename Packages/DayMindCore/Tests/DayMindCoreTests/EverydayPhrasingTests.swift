import XCTest
@testable import DayMindCore

/// Phrasings people actually use day to day, all handled by the offline interpreter
/// (the primary path on iPhones without Apple Intelligence).
final class EverydayPhrasingTests: XCTestCase {
    let i = Fixture.interpreter
    let p = Fixture.parser

    // MARK: Dates and times

    func testShorthandAndSpeechSpellings() {
        XCTAssertDate(p.parse("tmrw at 3pm")?.date, 2026, 9, 3, 15, 0)
        XCTAssertDate(p.parse("tonite at 8")?.date, 2026, 9, 2, 20, 0)
        XCTAssertDate(p.parse("noon tomorrow")?.date, 2026, 9, 3, 12, 0)
        XCTAssertDate(p.parse("3 o clock")?.date, 2026, 9, 2, 15, 0)
    }

    func testFractionsAndPartsOfDay() {
        XCTAssertDate(p.parse("half past 3")?.date, 2026, 9, 2, 15, 30)
        XCTAssertDate(p.parse("quarter to 4 tomorrow")?.date, 2026, 9, 3, 15, 45)
        XCTAssertDate(p.parse("5 tonight")?.date, 2026, 9, 2, 17, 0)
        XCTAssertDate(p.parse("at 7 in the morning tomorrow")?.date, 2026, 9, 3, 7, 0)
        XCTAssertDate(p.parse("3 in the afternoon")?.date, 2026, 9, 2, 15, 0)
        XCTAssertDate(p.parse("first thing tomorrow")?.date, 2026, 9, 3, 9, 0)
        XCTAssertDate(p.parse("tomorrow first thing")?.date, 2026, 9, 3, 9, 0)
    }

    func testRelativeWeeks() {
        XCTAssertDate(p.parse("a week from today")?.date, 2026, 9, 9, 9, 0)
        XCTAssertDate(p.parse("two weeks from now at 2 pm")?.date, 2026, 9, 16, 14, 0)
        XCTAssertDate(p.parse("tuesday next week")?.date, 2026, 9, 8, 9, 0)
        XCTAssertDate(p.parse("next week tuesday at 10")?.date, 2026, 9, 8, 10, 0)
        XCTAssertDate(p.parse("on the 3rd of next month")?.date, 2026, 10, 3, 9, 0)
    }

    // MARK: Reminder verbs

    func testReminderVerbVariants() {
        let sentences = [
            "set a reminder for tomorrow at 3 pm to call michael",
            "can you remind me tomorrow at 3 pm to call michael",
            "i want to be reminded tomorrow at 3 pm to call michael",
            "don't let me forget to call michael tomorrow at 3 pm",
            "add a reminder to call michael tomorrow at 3 pm",
            "hey daymind remind me tomorrow at 3 pm to call michael",
            "make a reminder for 3 pm tomorrow to call michael",
            "note to self: call michael tomorrow at 3 pm",
        ]
        for s in sentences {
            guard case .createReminder(let d) = i.interpret(s) else { return XCTFail("not a reminder: \(s)") }
            XCTAssertEqual(d.title, "Call Michael", s)
            XCTAssertDate(d.dueDate, 2026, 9, 3, 15, 0)
        }
    }

    func testNoteToSelfWithoutTimeIsAMemory() throws {
        guard case .saveMemory(let m) = i.interpret("write down that the wifi password is hunter2") else { return XCTFail() }
        XCTAssertEqual(m.content, "The wifi password is hunter2")
    }

    func testPlainStatementsBecomeMemories() throws {
        guard case .saveMemory(let m) = i.interpret("John's birthday is March 3") else { return XCTFail() }
        XCTAssertEqual(m.category, .person)
        guard case .saveMemory(let m2) = i.interpret("my car is a blue civic") else { return XCTFail() }
        XCTAssertEqual(m2.content, "My car is a blue civic")
        // Questions and chatter must not be saved.
        XCTAssertEqual(i.interpret("is it raining"), .unknown)
        XCTAssertEqual(i.interpret("that is great"), .unknown)
        XCTAssertEqual(i.interpret("ok thanks"), .unknown)
    }

    // MARK: Questions

    func testScheduleQuestions() {
        XCTAssertEqual(i.interpret("what do i have tomorrow"), .listReminders(.tomorrow))
        XCTAssertEqual(i.interpret("do i have anything today"), .listReminders(.today))
        XCTAssertEqual(i.interpret("what's on my schedule"), .listReminders(.today))
        XCTAssertEqual(i.interpret("what am i doing this week"), .listReminders(.upcoming))
        XCTAssertEqual(i.interpret("anything due"), .listReminders(.today))
        XCTAssertEqual(i.interpret("read me my reminders"), .listReminders(.all))
        XCTAssertEqual(i.interpret("how many reminders do i have"), .listReminders(.all))
        XCTAssertEqual(i.interpret("good morning"), .dailyBriefing)
        XCTAssertEqual(i.interpret("what does my day look like"), .dailyBriefing)
    }

    func testMemoryQuestions() {
        XCTAssertEqual(i.interpret("what does michael like"), .searchMemories(query: "michael"))
        XCTAssertEqual(i.interpret("do you know anything about the plumber"), .searchMemories(query: "plumber"))
        XCTAssertEqual(i.interpret("when is john's birthday"), .searchMemories(query: "john's birthday"))
        XCTAssertEqual(i.interpret("remind me what we decided about the countertop"), .searchMemories(query: "we decided about the countertop"))
    }

    // MARK: Edits

    func testEditVariants() throws {
        guard case .rescheduleReminder(let r1, let d1, _) = i.interpret("make it 5 pm") else { return XCTFail() }
        XCTAssertTrue(r1.usesAnaphora); XCTAssertDate(d1, 2026, 9, 2, 17, 0)
        guard case .rescheduleReminder(let r2, let d2, _) = i.interpret("push it to tomorrow") else { return XCTFail() }
        XCTAssertTrue(r2.usesAnaphora); XCTAssertDate(d2, 2026, 9, 3, 9, 0)
        guard case .rescheduleReminder(_, let d3, _) = i.interpret("actually make that friday at 10") else { return XCTFail() }
        XCTAssertDate(d3, 2026, 9, 4, 10, 0)
        guard case .rescheduleReminder(let r4, let d4, _) = i.interpret("bump the plumber reminder to next week tuesday") else { return XCTFail() }
        XCTAssertEqual(r4.titleHint, "plumber"); XCTAssertDate(d4, 2026, 9, 8, 9, 0)
        guard case .completeReminder(let r5) = i.interpret("done") else { return XCTFail() }
        XCTAssertTrue(r5.usesAnaphora)
        guard case .completeReminder(let r6) = i.interpret("check the plumber off") else { return XCTFail() }
        XCTAssertEqual(r6.titleHint, "plumber")
        guard case .deleteReminder(let r7) = i.interpret("never mind, scratch that") else { return XCTFail() }
        XCTAssertTrue(r7.usesAnaphora)
        guard case .deleteReminder(let r8) = i.interpret("cancel that reminder") else { return XCTFail() }
        XCTAssertTrue(r8.usesAnaphora)
    }
}
