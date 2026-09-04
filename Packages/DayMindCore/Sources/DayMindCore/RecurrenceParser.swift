import Foundation

/// Extracts recurrence phrases ("every Monday morning", "every first Monday of the month at 9 AM",
/// "daily", "every other week") from free text.
public struct RecurrenceParser: Sendable {
    public struct Result: Equatable, Sendable {
        public var rule: RecurrenceRule
        /// Time of day that the phrase itself implied (e.g. "every morning"), if any.
        public var impliedTime: TimeOfDay?
        public var remainder: String
        public var matchedPhrase: String
    }

    public var calendar: Calendar
    public var defaults: TimeDefaults

    public init(calendar: Calendar = .current, defaults: TimeDefaults = .standard) {
        self.calendar = calendar
        self.defaults = defaults
    }

    static let ordinals: [String: Int] = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "last": -1]

    public func parse(_ text: String) -> Result? {
        let s = NaturalDateParser.normalize(text)
        let wd = NaturalDateParser.weekdayPattern
        let mo = NaturalDateParser.monthPattern

        // every (first|second|third|fourth|last) monday of (the|every) month
        if let m = first("\\bevery\\s+(first|second|third|fourth|last|1st|2nd|3rd|4th)\\s+\(wd)\\s+of\\s+(?:the|every|each)\\s+month\\b", in: s),
           let ord = Self.ordinals[cap(m, 1)], let weekday = NaturalDateParser.weekdayNames[cap(m, 2)] {
            return make(RecurrenceRule(frequency: .monthly, weekdays: [weekday], weekOfMonth: ord), s, m.range, nil)
        }
        if let m = first("\\b(?:on\\s+)?the\\s+(first|second|third|fourth|last|1st|2nd|3rd|4th)\\s+\(wd)\\s+of\\s+(?:the|every|each)\\s+month\\b", in: s),
           let ord = Self.ordinals[cap(m, 1)], let weekday = NaturalDateParser.weekdayNames[cap(m, 2)] {
            return make(RecurrenceRule(frequency: .monthly, weekdays: [weekday], weekOfMonth: ord), s, m.range, nil)
        }
        // every weekday / every weekday morning
        if let m = first(#"\bevery\s+weekday(?:\s+(morning|afternoon|evening|night))?\b"#, in: s) {
            return make(.weekdays, s, m.range, vague(cap(m, 1)))
        }
        if let m = first(#"\b(?:on\s+)?weekdays\b"#, in: s) {
            return make(.weekdays, s, m.range, nil)
        }
        // every monday (and wednesday) (morning)
        if let m = first("\\bevery\\s+\(wd)(?:\\s*(?:,|and|&)\\s*\(wd))?(?:\\s*(?:,|and|&)\\s*\(wd))?(?:\\s+(morning|afternoon|evening|night))?\\b", in: s) {
            let days = [cap(m, 1), cap(m, 2), cap(m, 3)].compactMap { NaturalDateParser.weekdayNames[$0] }
            if !days.isEmpty {
                return make(RecurrenceRule(frequency: .weekly, weekdays: days), s, m.range, vague(cap(m, 4)))
            }
        }
        // on mondays / mondays and wednesdays
        if let m = first("\\b(?:on\\s+)?\(wd)s(?:\\s*(?:,|and|&)\\s*\(wd)s)?\\b", in: s) {
            let days = [cap(m, 1), cap(m, 2)].compactMap { NaturalDateParser.weekdayNames[$0] }
            if !days.isEmpty {
                return make(RecurrenceRule(frequency: .weekly, weekdays: days), s, m.range, nil)
            }
        }
        // every other day/week/month/year ; every 2 weeks ; every two weeks
        if let m = first(#"\bevery\s+(other|\d+|two|three|four|five|six)\s+(days?|weeks?|months?|years?)\b"#, in: s) {
            let n = cap(m, 1) == "other" ? 2 : (NaturalDateParser.number(from: cap(m, 1)) ?? 1)
            return make(RecurrenceRule(frequency: freq(cap(m, 2)), interval: n), s, m.range, nil)
        }
        // every day / every morning / daily / everyday / each day / every night
        if let m = first(#"\b(?:every|each)\s+(day|morning|afternoon|evening|night)\b|\b(daily|everyday|nightly)\b"#, in: s) {
            let word = cap(m, 1).isEmpty ? cap(m, 2) : cap(m, 1)
            let implied: TimeOfDay? = word == "nightly" ? defaults.night : vague(word)
            return make(.daily, s, m.range, implied)
        }
        // every month on the 15th / monthly on the 1st
        if let m = first(#"\b(?:every|each)\s+month\s+on\s+the\s+(\d{1,2})(?:st|nd|rd|th)?\b|\bmonthly\s+on\s+the\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, in: s),
           let d = Int(cap(m, 1).isEmpty ? cap(m, 2) : cap(m, 1)) {
            return make(RecurrenceRule(frequency: .monthly, dayOfMonth: d), s, m.range, nil)
        }
        // every september 11 / every year on september 11
        if let m = first("\\bevery\\s+(?:year\\s+on\\s+)?\(mo)\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b", in: s),
           let month = NaturalDateParser.monthNames[cap(m, 1)], let d = Int(cap(m, 2)) {
            return make(RecurrenceRule(frequency: .yearly, dayOfMonth: d, monthOfYear: month), s, m.range, nil)
        }
        // every week / weekly ; every month / monthly ; every year / yearly / annually
        if let m = first(#"\b(?:every|each)\s+(week|month|year)\b|\b(weekly|monthly|yearly|annually)\b"#, in: s) {
            let word = cap(m, 1).isEmpty ? cap(m, 2) : cap(m, 1)
            return make(RecurrenceRule(frequency: freq(word)), s, m.range, nil)
        }
        return nil
    }

    // MARK: helpers

    private func first(_ pattern: String, in text: String) -> Regex<AnyRegexOutput>.Match? {
        guard let regex = try? Regex(pattern).ignoresCase() else { return nil }
        return text.firstMatch(of: regex)
    }

    private func cap(_ m: Regex<AnyRegexOutput>.Match, _ i: Int) -> String {
        guard i < m.output.count, let sub = m.output[i].substring else { return "" }
        return String(sub).lowercased()
    }

    private func vague(_ word: String) -> TimeOfDay? {
        switch word {
        case "morning": return defaults.morning
        case "afternoon": return defaults.afternoon
        case "evening": return defaults.evening
        case "night": return defaults.night
        default: return nil
        }
    }

    private func freq(_ word: String) -> RecurrenceRule.Frequency {
        if word.hasPrefix("day") || word == "daily" { return .daily }
        if word.hasPrefix("week") { return .weekly }
        if word.hasPrefix("month") { return .monthly }
        return .yearly
    }

    private func make(_ rule: RecurrenceRule, _ text: String, _ range: Range<String.Index>, _ implied: TimeOfDay?) -> Result {
        Result(rule: rule, impliedTime: implied, remainder: NaturalDateParser.remainder(of: text, removing: [range]), matchedPhrase: String(text[range]))
    }
}
