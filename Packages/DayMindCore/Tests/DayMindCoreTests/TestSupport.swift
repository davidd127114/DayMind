import Foundation
import XCTest
@testable import DayMindCore

/// Fixed clock for deterministic tests: Wednesday, 2 September 2026, 10:00 in New York.
enum Fixture {
    static var timeZone: TimeZone {
        TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -4 * 3600)!
    }

    static var hasRealTimeZoneDatabase: Bool { TimeZone(identifier: "America/New_York") != nil }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 1
        return c
    }

    static var now: Date { date(2026, 9, 2, 10, 0) }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static var parser: NaturalDateParser { NaturalDateParser(calendar: calendar, now: now, defaults: .standard) }
    static var interpreter: RuleBasedInterpreter { RuleBasedInterpreter(calendar: calendar, now: now, defaults: .standard) }

    static func components(_ date: Date) -> (y: Int, m: Int, d: Int, h: Int, min: Int) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}

func XCTAssertDate(_ date: Date?, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, file: StaticString = #filePath, line: UInt = #line) {
    guard let date else { XCTFail("date was nil", file: file, line: line); return }
    let c = Fixture.components(date)
    XCTAssertEqual([c.y, c.m, c.d, c.h, c.min], [y, m, d, h, min], "got \(c)", file: file, line: line)
}
