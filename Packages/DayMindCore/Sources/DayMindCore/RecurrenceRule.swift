import Foundation

/// A real recurrence rule (RFC 5545-inspired) evaluated with `Calendar`, so daylight-saving
/// transitions and month lengths are handled by Foundation rather than by arithmetic on seconds.
///
/// The *time of day* of each occurrence comes from the `anchor` date (the reminder's first due date).
public struct RecurrenceRule: Codable, Equatable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable, Identifiable {
        case daily, weekly, monthly, yearly
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    public var frequency: Frequency
    /// Every `interval` days/weeks/months/years. Minimum 1.
    public var interval: Int
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday. Used by `.weekly`, and by `.monthly`
    /// together with `weekOfMonth` ("first Monday of the month"). Empty = use the anchor's weekday.
    public var weekdays: [Int]
    /// 1…31 for `.monthly` / `.yearly`. Values past the end of a month clamp to the last day.
    public var dayOfMonth: Int?
    /// 1…4 or -1 for "last", used with exactly one weekday for `.monthly`.
    public var weekOfMonth: Int?
    /// 1…12 for `.yearly`.
    public var monthOfYear: Int?
    /// No occurrences are produced after this date.
    public var endDate: Date?

    public init(frequency: Frequency,
                interval: Int = 1,
                weekdays: [Int] = [],
                dayOfMonth: Int? = nil,
                weekOfMonth: Int? = nil,
                monthOfYear: Int? = nil,
                endDate: Date? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        self.dayOfMonth = dayOfMonth.map { min(max($0, 1), 31) }
        self.weekOfMonth = weekOfMonth
        self.monthOfYear = monthOfYear.map { min(max($0, 1), 12) }
        self.endDate = endDate
    }

    public static let daily = RecurrenceRule(frequency: .daily)
    public static let weekdays = RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])

    // MARK: Evaluation

    /// Whether `day` (any instant within the day) is an occurrence day relative to `anchor`.
    public func matches(day: Date, anchor: Date, calendar: Calendar) -> Bool {
        let anchorDay = calendar.startOfDay(for: anchor)
        let candidate = calendar.startOfDay(for: day)
        guard candidate >= anchorDay else { return false }
        if let endDate, candidate > calendar.startOfDay(for: endDate) { return false }

        switch frequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: anchorDay, to: candidate).day ?? 0
            return days % interval == 0

        case .weekly:
            let wanted = weekdays.isEmpty ? [calendar.component(.weekday, from: anchor)] : weekdays
            let weekday = calendar.component(.weekday, from: candidate)
            guard wanted.contains(weekday) else { return false }
            guard interval > 1 else { return true }
            guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDay)?.start,
                  let candidateWeek = calendar.dateInterval(of: .weekOfYear, for: candidate)?.start else { return false }
            let days = calendar.dateComponents([.day], from: anchorWeek, to: candidateWeek).day ?? 0
            return (days / 7) % interval == 0

        case .monthly:
            let anchorMonth = calendar.dateComponents([.year, .month], from: anchorDay)
            let candMonth = calendar.dateComponents([.year, .month], from: candidate)
            let months = ((candMonth.year ?? 0) - (anchorMonth.year ?? 0)) * 12 + ((candMonth.month ?? 0) - (anchorMonth.month ?? 0))
            guard months % interval == 0 else { return false }
            if let weekOfMonth, let weekday = weekdays.first {
                guard calendar.component(.weekday, from: candidate) == weekday else { return false }
                if weekOfMonth == -1 {
                    // Last such weekday in the month: adding 7 days must leave the month.
                    guard let plusWeek = calendar.date(byAdding: .day, value: 7, to: candidate) else { return false }
                    return calendar.component(.month, from: plusWeek) != calendar.component(.month, from: candidate)
                }
                return calendar.component(.weekdayOrdinal, from: candidate) == weekOfMonth
            }
            let wantedDay = dayOfMonth ?? calendar.component(.day, from: anchorDay)
            let daysInMonth = calendar.range(of: .day, in: .month, for: candidate)?.count ?? 31
            return calendar.component(.day, from: candidate) == min(wantedDay, daysInMonth)

        case .yearly:
            let anchorYear = calendar.component(.year, from: anchorDay)
            let candYear = calendar.component(.year, from: candidate)
            guard (candYear - anchorYear) % interval == 0 else { return false }
            let wantedMonth = monthOfYear ?? calendar.component(.month, from: anchorDay)
            guard calendar.component(.month, from: candidate) == wantedMonth else { return false }
            let wantedDay = dayOfMonth ?? calendar.component(.day, from: anchorDay)
            let daysInMonth = calendar.range(of: .day, in: .month, for: candidate)?.count ?? 31
            return calendar.component(.day, from: candidate) == min(wantedDay, daysInMonth)
        }
    }

    /// The first occurrence strictly after `date`, using the anchor's time of day.
    /// Searches up to ten years ahead; returns `nil` when the rule has ended.
    public func nextOccurrence(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        let hour = calendar.component(.hour, from: anchor)
        let minute = calendar.component(.minute, from: anchor)
        let startDay = calendar.startOfDay(for: max(date, calendar.startOfDay(for: anchor)))
        let maxDays = 366 * 10
        for offset in 0...maxDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            if let endDate, day > calendar.startOfDay(for: endDate) { return nil }
            guard matches(day: day, anchor: anchor, calendar: calendar) else { continue }
            guard let instant = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if instant > date { return instant }
        }
        return nil
    }

    public func occurrences(after date: Date, anchor: Date, calendar: Calendar, limit: Int) -> [Date] {
        var out: [Date] = []
        var cursor = date
        while out.count < limit, let next = nextOccurrence(after: cursor, anchor: anchor, calendar: calendar) {
            out.append(next)
            cursor = next
        }
        return out
    }

    /// If this rule can be expressed as a single repeating `DateComponents` trigger
    /// (as `UNCalendarNotificationTrigger(repeats: true)` needs), return those components.
    /// Rules with intervals, multiple weekdays, or ordinals ("first Monday") return `nil`
    /// and must be scheduled one occurrence at a time.
    public func repeatingTriggerComponents(anchor: Date, calendar: Calendar) -> DateComponents? {
        guard interval == 1, endDate == nil else { return nil }
        var comps = DateComponents()
        comps.hour = calendar.component(.hour, from: anchor)
        comps.minute = calendar.component(.minute, from: anchor)
        switch frequency {
        case .daily:
            return comps
        case .weekly:
            let wanted = weekdays.isEmpty ? [calendar.component(.weekday, from: anchor)] : weekdays
            guard wanted.count == 1 else { return nil }
            comps.weekday = wanted[0]
            return comps
        case .monthly:
            guard weekOfMonth == nil else { return nil }
            let day = dayOfMonth ?? calendar.component(.day, from: anchor)
            guard day <= 28 else { return nil } // avoid months that lack the day
            comps.day = day
            return comps
        case .yearly:
            comps.month = monthOfYear ?? calendar.component(.month, from: anchor)
            let day = dayOfMonth ?? calendar.component(.day, from: anchor)
            guard !(comps.month == 2 && day == 29) else { return nil }
            comps.day = day
            return comps
        }
    }

    // MARK: Description

    public func humanDescription(anchor: Date?, calendar: Calendar, locale: Locale = .current) -> String {
        var base: String
        let every = interval == 1 ? "every" : "every \(interval)"
        switch frequency {
        case .daily:
            base = interval == 1 ? "every day" : "every \(interval) days"
        case .weekly:
            let wanted = weekdays.isEmpty ? (anchor.map { [calendar.component(.weekday, from: $0)] } ?? []) : weekdays
            if wanted == [2, 3, 4, 5, 6] {
                base = interval == 1 ? "every weekday" : "every \(interval) weeks on weekdays"
            } else if wanted.isEmpty {
                base = interval == 1 ? "every week" : "every \(interval) weeks"
            } else {
                let names = wanted.map { Self.weekdayName($0, calendar: calendar) }
                base = interval == 1 ? "every \(Self.joinList(names))" : "every \(interval) weeks on \(Self.joinList(names))"
            }
        case .monthly:
            if let weekOfMonth, let weekday = weekdays.first {
                let ordinal = Self.ordinalName(weekOfMonth)
                base = "the \(ordinal) \(Self.weekdayName(weekday, calendar: calendar)) of \(interval == 1 ? "every month" : "every \(interval) months")"
            } else {
                let day = dayOfMonth ?? anchor.map { calendar.component(.day, from: $0) } ?? 1
                base = "\(every) month\(interval == 1 ? "" : "s") on the \(Self.ordinalDay(day))"
            }
        case .yearly:
            let month = monthOfYear ?? anchor.map { calendar.component(.month, from: $0) } ?? 1
            let day = dayOfMonth ?? anchor.map { calendar.component(.day, from: $0) } ?? 1
            let monthName = calendar.monthSymbols[max(0, min(11, month - 1))]
            base = "\(every) year\(interval == 1 ? "" : "s") on \(monthName) \(day)"
        }
        if let anchor {
            base += " at \(SpokenFormatter.timeString(anchor, calendar: calendar, locale: locale))"
        }
        return base
    }

    public static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let symbols = calendar.weekdaySymbols
        let index = max(0, min(6, weekday - 1))
        return symbols[index]
    }

    public static func ordinalName(_ n: Int) -> String {
        switch n {
        case -1: return "last"
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        default: return "\(n)th"
        }
    }

    static func ordinalDay(_ day: Int) -> String {
        let suffix: String
        switch day % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }

    public static func joinList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
