import XCTest
@testable import DayMindCore

final class NaturalDateParserTests: XCTestCase {
    let p = Fixture.parser

    func testTomorrowAtThreePM() {
        let r = p.parse("remind me tomorrow at 3 pm to call michael")
        XCTAssertDate(r?.date, 2026, 9, 3, 15, 0)
        XCTAssertEqual(r?.hasExplicitTime, true)
        XCTAssertEqual(r?.remainder, "remind me to call michael")
    }

    func testBareHourAssumesAfternoonForSmallNumbers() {
        XCTAssertDate(p.parse("tomorrow at 3")?.date, 2026, 9, 3, 15, 0)
        // 10:00 now; "at 8" → 8 AM already passed today → tomorrow 8 AM
        XCTAssertDate(p.parse("at 8")?.date, 2026, 9, 3, 8, 0)
        XCTAssertDate(p.parse("at 11")?.date, 2026, 9, 2, 11, 0)
    }

    func testThisFridayVersusNextFriday() {
        // Today is Wednesday 2 Sep 2026. Coming Friday = 4 Sep. "next Friday" = 11 Sep.
        XCTAssertDate(p.parse("friday at 10")?.date, 2026, 9, 4, 10, 0)
        XCTAssertDate(p.parse("on friday at 10 am")?.date, 2026, 9, 4, 10, 0)
        XCTAssertDate(p.parse("next friday at 10")?.date, 2026, 9, 11, 10, 0)
    }

    func testDurations() {
        XCTAssertDate(p.parse("in two hours")?.date, 2026, 9, 2, 12, 0)
        XCTAssertDate(p.parse("in 30 minutes")?.date, 2026, 9, 2, 10, 30)
        XCTAssertDate(p.parse("in half an hour")?.date, 2026, 9, 2, 10, 30)
        XCTAssertDate(p.parse("in 3 days at 5 pm")?.date, 2026, 9, 5, 17, 0)
        XCTAssertEqual(p.parse("in two hours")?.isRelativeDuration, true)
    }

    func testMonthDayAndISO() {
        XCTAssertDate(p.parse("september 11")?.date, 2026, 9, 11, 9, 0)          // morning default
        XCTAssertDate(p.parse("on sept 11th at 10:30 am")?.date, 2026, 9, 11, 10, 30)
        XCTAssertDate(p.parse("11 september at noon")?.date, 2026, 9, 11, 12, 0)
        XCTAssertDate(p.parse("january 5")?.date, 2027, 1, 5, 9, 0)             // past this year → next year
        XCTAssertDate(p.parse("9/11 at 4pm")?.date, 2026, 9, 11, 16, 0)
        XCTAssertDate(p.resolve(dateExpression: "2026-09-11", timeExpression: "10:00")?.date, 2026, 9, 11, 10, 0)
        XCTAssertDate(p.resolve(dateExpression: "2026-09-11T10:00:00", timeExpression: nil)?.date, 2026, 9, 11, 10, 0)
        XCTAssertDate(p.resolve(dateExpression: "tomorrow", timeExpression: "3 pm")?.date, 2026, 9, 3, 15, 0)
    }

    func testVagueWords() {
        XCTAssertDate(p.parse("tonight")?.date, 2026, 9, 2, 18, 0)
        XCTAssertDate(p.parse("tomorrow morning")?.date, 2026, 9, 3, 9, 0)
        XCTAssertDate(p.parse("monday morning")?.date, 2026, 9, 7, 9, 0)
        XCTAssertDate(p.parse("tomorrow evening")?.date, 2026, 9, 3, 18, 0)
        XCTAssertDate(p.parse("this afternoon")?.date, 2026, 9, 2, 14, 0)
        XCTAssertDate(p.parse("on the 15th")?.date, 2026, 9, 15, 9, 0)
        XCTAssertDate(p.parse("next week")?.date, 2026, 9, 7, 9, 0)
    }

    func testConfigurableDefaults() {
        var d = TimeDefaults.standard
        d.morning = TimeOfDay(hour: 7, minute: 30)
        let custom = NaturalDateParser(calendar: Fixture.calendar, now: Fixture.now, defaults: d)
        XCTAssertDate(custom.parse("tomorrow morning")?.date, 2026, 9, 3, 7, 30)
    }

    func testAmbiguousReturnsNil() {
        XCTAssertNil(p.parse("later"))
        XCTAssertNil(p.parse("remind me to call michael"))
        XCTAssertNil(p.resolve(dateExpression: nil, timeExpression: nil))
    }

    func testRemainderIsClean() {
        XCTAssertEqual(p.parse("call michael tomorrow at 3 pm")?.remainder, "call michael")
        XCTAssertEqual(p.parse("pay rent on the 1st of october")?.remainder, "pay rent")
    }
}
