import XCTest
@testable import DayMindCore

final class RecurrenceRuleTests: XCTestCase {
    let cal = Fixture.calendar

    func testWeeklyMonday() {
        let anchor = Fixture.date(2026, 9, 7, 9, 0) // Monday
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [2])
        XCTAssertDate(rule.nextOccurrence(after: anchor, anchor: anchor, calendar: cal), 2026, 9, 14, 9, 0)
        XCTAssertDate(rule.nextOccurrence(after: Fixture.now, anchor: anchor, calendar: cal), 2026, 9, 7, 9, 0)
        XCTAssertEqual(rule.humanDescription(anchor: anchor, calendar: cal, locale: Locale(identifier: "en_US")), "every Monday at 9:00 AM")
        let comps = rule.repeatingTriggerComponents(anchor: anchor, calendar: cal)
        XCTAssertEqual(comps?.weekday, 2)
        XCTAssertEqual(comps?.hour, 9)
    }

    func testFirstMondayOfMonth() {
        let anchor = Fixture.date(2026, 9, 7, 9, 0) // first Monday of September 2026
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1)
        let next = rule.occurrences(after: anchor, anchor: anchor, calendar: cal, limit: 3)
        XCTAssertEqual(next.count, 3)
        XCTAssertDate(next[0], 2026, 10, 5, 9, 0)
        XCTAssertDate(next[1], 2026, 11, 2, 9, 0)
        XCTAssertDate(next[2], 2026, 12, 7, 9, 0)
        XCTAssertNil(rule.repeatingTriggerComponents(anchor: anchor, calendar: cal), "ordinal rules cannot use a single repeating trigger")
        XCTAssertEqual(rule.humanDescription(anchor: anchor, calendar: cal, locale: Locale(identifier: "en_US")), "the first Monday of every month at 9:00 AM")
    }

    func testLastFridayOfMonth() {
        let anchor = Fixture.date(2026, 9, 25, 17, 0)
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [6], weekOfMonth: -1)
        XCTAssertDate(rule.nextOccurrence(after: anchor, anchor: anchor, calendar: cal), 2026, 10, 30, 17, 0)
    }

    func testMonthlyDayClamps() {
        let anchor = Fixture.date(2026, 1, 31, 8, 0)
        let rule = RecurrenceRule(frequency: .monthly)
        let next = rule.occurrences(after: anchor, anchor: anchor, calendar: cal, limit: 3)
        XCTAssertDate(next[0], 2026, 2, 28, 8, 0)
        XCTAssertDate(next[1], 2026, 3, 31, 8, 0)
        XCTAssertDate(next[2], 2026, 4, 30, 8, 0)
    }

    func testEveryOtherWeek() {
        let anchor = Fixture.date(2026, 9, 7, 9, 0)
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2])
        let next = rule.occurrences(after: anchor, anchor: anchor, calendar: cal, limit: 2)
        XCTAssertDate(next[0], 2026, 9, 21, 9, 0)
        XCTAssertDate(next[1], 2026, 10, 5, 9, 0)
    }

    func testDailyAcrossDaylightSavingEnd() throws {
        try XCTSkipUnless(Fixture.hasRealTimeZoneDatabase, "No IANA time-zone database on this platform")
        // US DST ends 1 Nov 2026 at 2:00 AM.
        let anchor = Fixture.date(2026, 10, 30, 9, 0)
        let rule = RecurrenceRule.daily
        let next = rule.occurrences(after: anchor, anchor: anchor, calendar: cal, limit: 3)
        XCTAssertDate(next[0], 2026, 10, 31, 9, 0)
        XCTAssertDate(next[1], 2026, 11, 1, 9, 0)
        XCTAssertDate(next[2], 2026, 11, 2, 9, 0)
        // The wall-clock hour stays 9 even though the day is 25 hours long.
        XCTAssertEqual(next[1].timeIntervalSince(next[0]), 25 * 3600, accuracy: 1)
    }

    func testDailyAcrossDaylightSavingStart() throws {
        try XCTSkipUnless(Fixture.hasRealTimeZoneDatabase, "No IANA time-zone database on this platform")
        // US DST starts 8 Mar 2026 at 2:00 AM.
        let anchor = Fixture.date(2026, 3, 7, 2, 30)
        let next = RecurrenceRule.daily.nextOccurrence(after: anchor, anchor: anchor, calendar: cal)
        // 2:30 AM does not exist on 8 March; Foundation shifts to the next valid time (3:30).
        XCTAssertNotNil(next)
        XCTAssertEqual(Fixture.components(next!).d, 8)
    }

    func testYearly() {
        let anchor = Fixture.date(2026, 9, 11, 9, 0)
        let rule = RecurrenceRule(frequency: .yearly, dayOfMonth: 11, monthOfYear: 9)
        XCTAssertDate(rule.nextOccurrence(after: anchor, anchor: anchor, calendar: cal), 2027, 9, 11, 9, 0)
    }

    func testEndDateStopsOccurrences() {
        let anchor = Fixture.date(2026, 9, 7, 9, 0)
        let rule = RecurrenceRule(frequency: .weekly, weekdays: [2], endDate: Fixture.date(2026, 9, 20))
        XCTAssertDate(rule.nextOccurrence(after: anchor, anchor: anchor, calendar: cal), 2026, 9, 14, 9, 0)
        XCTAssertNil(rule.nextOccurrence(after: Fixture.date(2026, 9, 14, 9, 0), anchor: anchor, calendar: cal))
    }

    func testCodableRoundTrip() throws {
        let rule = RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1)
        let data = try DayMindJSON.encoder().encode(rule)
        let back = try DayMindJSON.decoder().decode(RecurrenceRule.self, from: data)
        XCTAssertEqual(rule, back)
    }
}
