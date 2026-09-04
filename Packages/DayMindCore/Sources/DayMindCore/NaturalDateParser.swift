import Foundation

/// Default clock times for vague words. All configurable in Settings.
public struct TimeOfDay: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
    public var totalMinutes: Int { hour * 60 + minute }
}

public struct TimeDefaults: Codable, Equatable, Hashable, Sendable {
    public var morning: TimeOfDay
    public var afternoon: TimeOfDay
    public var evening: TimeOfDay
    public var night: TimeOfDay

    public init(morning: TimeOfDay = TimeOfDay(hour: 9),
                afternoon: TimeOfDay = TimeOfDay(hour: 14),
                evening: TimeOfDay = TimeOfDay(hour: 18),
                night: TimeOfDay = TimeOfDay(hour: 20)) {
        self.morning = morning
        self.afternoon = afternoon
        self.evening = evening
        self.night = night
    }

    public static let standard = TimeDefaults()
}

/// Result of extracting a date/time from free text.
public struct ParsedDateTime: Equatable, Sendable {
    public var date: Date
    public var hasExplicitDate: Bool
    public var hasExplicitTime: Bool
    /// True for "in 2 hours"-style durations (time is exact, derived from now).
    public var isRelativeDuration: Bool
    /// The input with the recognised date/time words removed and whitespace tidied.
    public var remainder: String
    /// The exact phrases that were consumed, for display/debugging.
    public var matchedPhrases: [String]
}

/// Deterministic natural-language date/time parser (English). Used both by the deterministic
/// fallback (when Apple Intelligence is unavailable) and to resolve the date expressions the
/// on-device model extracts — small language models are unreliable at calendar arithmetic, so
/// the model only has to say *"next friday"* / *"3 pm"* and this code does the math.
public struct NaturalDateParser: Sendable {
    public var calendar: Calendar
    public var now: Date
    public var defaults: TimeDefaults

    public init(calendar: Calendar = .current, now: Date = Date(), defaults: TimeDefaults = .standard) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
    }

    // MARK: Public API

    /// Resolve model-provided expressions such as ("tomorrow", "3 pm") or ("2026-09-11", nil).
    public func resolve(dateExpression: String?, timeExpression: String?) -> ParsedDateTime? {
        let combined = [dateExpression, timeExpression].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !combined.isEmpty else { return nil }
        if let iso = Self.parseISO(combined, calendar: calendar) {
            return ParsedDateTime(date: iso.date, hasExplicitDate: true, hasExplicitTime: iso.hasTime, isRelativeDuration: false, remainder: "", matchedPhrases: [combined])
        }
        return parse(combined)
    }

    /// Find a date and/or time anywhere in `text`.
    public func parse(_ text: String) -> ParsedDateTime? {
        let normalized = Self.normalize(text)
        var consumed: [Range<String.Index>] = []
        var phrases: [String] = []

        // 1. Time
        var time: (hour: Int, minute: Int)? = nil
        var vagueTime: VagueTime? = nil
        var explicitTime = false
        if let m = firstTimeMatch(in: normalized, excluding: consumed) {
            time = m.time
            vagueTime = m.vague
            explicitTime = m.time != nil
            consumed.append(m.range)
            phrases.append(String(normalized[m.range]))
        }

        // 2. Duration ("in 2 hours")
        if let d = durationMatch(in: normalized, excluding: consumed) {
            consumed.append(d.range)
            phrases.append(String(normalized[d.range]))
            let base = now
            guard var date = calendar.date(byAdding: d.component, value: d.value, to: base) else { return nil }
            if d.component == .day || d.component == .weekOfYear || d.component == .month || d.component == .year {
                // "in 3 days at 5 pm" → apply time if provided; otherwise keep the current clock time.
                if let time { date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date }
                else if let vagueTime { let t = clock(for: vagueTime); date = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: date) ?? date }
            }
            return ParsedDateTime(date: date, hasExplicitDate: true, hasExplicitTime: true, isRelativeDuration: true,
                                  remainder: Self.remainder(of: normalized, removing: consumed), matchedPhrases: phrases)
        }

        // 3. Date
        var day: Date? = nil
        var explicitDate = false
        if let d = firstDateMatch(in: normalized, excluding: consumed) {
            day = d.day
            explicitDate = true
            consumed.append(d.range)
            phrases.append(String(normalized[d.range]))
            if d.impliedVague != nil, vagueTime == nil, time == nil { vagueTime = d.impliedVague }
        }

        guard explicitDate || explicitTime || vagueTime != nil else { return nil }

        // 4. Combine
        let clockTime: (hour: Int, minute: Int)
        if let time { clockTime = time }
        else if let vagueTime { let t = clock(for: vagueTime); clockTime = (t.hour, t.minute) }
        else { clockTime = (defaults.morning.hour, defaults.morning.minute) }

        var baseDay = day ?? calendar.startOfDay(for: now)
        var result = calendar.date(bySettingHour: clockTime.hour, minute: clockTime.minute, second: 0, of: baseDay) ?? baseDay
        if !explicitDate, result <= now {
            // "at 3" said after 3 pm means tomorrow at 3.
            baseDay = calendar.date(byAdding: .day, value: 1, to: baseDay) ?? baseDay
            result = calendar.date(bySettingHour: clockTime.hour, minute: clockTime.minute, second: 0, of: baseDay) ?? result
        }
        return ParsedDateTime(date: result, hasExplicitDate: explicitDate, hasExplicitTime: explicitTime || vagueTime != nil,
                              isRelativeDuration: false, remainder: Self.remainder(of: normalized, removing: consumed), matchedPhrases: phrases)
    }

    // MARK: Vocabulary

    enum VagueTime { case morning, afternoon, evening, night, noon, midnight }

    func clock(for v: VagueTime) -> TimeOfDay {
        switch v {
        case .morning: return defaults.morning
        case .afternoon: return defaults.afternoon
        case .evening: return defaults.evening
        case .night: return defaults.night
        case .noon: return TimeOfDay(hour: 12)
        case .midnight: return TimeOfDay(hour: 0)
        }
    }

    static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]
    static let weekdayPattern = "(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)"

    static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    static let monthPattern = "(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "fortyfive": 45, "sixty": 60, "ninety": 90, "couple": 2, "few": 3, "half": 0,
    ]

    public static func number(from word: String) -> Int? {
        if let n = Int(word) { return n }
        return numberWords[word]
    }

    // MARK: Matching helpers

    struct TimeMatch { var range: Range<String.Index>; var time: (hour: Int, minute: Int)?; var vague: VagueTime? }
    struct DurationMatch { var range: Range<String.Index>; var component: Calendar.Component; var value: Int }
    struct DateMatch { var range: Range<String.Index>; var day: Date; var impliedVague: VagueTime? }

    private func overlaps(_ r: Range<String.Index>, _ ranges: [Range<String.Index>]) -> Bool {
        ranges.contains { $0.overlaps(r) }
    }

    private func firstMatch(_ pattern: String, in text: String, excluding: [Range<String.Index>]) -> Regex<AnyRegexOutput>.Match? {
        guard let regex = try? Regex(pattern).ignoresCase() else { return nil }
        for m in text.matches(of: regex) where !overlaps(m.range, excluding) {
            return m
        }
        return nil
    }

    private func capture(_ m: Regex<AnyRegexOutput>.Match, _ i: Int) -> String? {
        guard i < m.output.count, let sub = m.output[i].substring else { return nil }
        return String(sub)
    }

    private func firstTimeMatch(in text: String, excluding: [Range<String.Index>]) -> TimeMatch? {
        // 15:00 / 3:30 pm / 3pm / at 3 / 3 o'clock / noon / midnight / morning …
        // Order matters: most specific first.
        if let m = firstMatch(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?=\b|\s|$)"#, in: text, excluding: excluding),
           let h = capture(m, 1).flatMap(Int.init) {
            let minute = capture(m, 2).flatMap(Int.init) ?? 0
            let isPM = (capture(m, 3) ?? "").lowercased().hasPrefix("p")
            var hour = h % 12
            if isPM { hour += 12 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return TimeMatch(range: m.range, time: (hour, minute), vague: nil)
        }
        if let m = firstMatch(#"\b(noon|midday|midnight)\b"#, in: text, excluding: excluding) {
            let word = (capture(m, 1) ?? "").lowercased()
            return TimeMatch(range: m.range, time: nil, vague: word == "midnight" ? .midnight : .noon)
        }
        if let m = firstMatch(#"\b(?:at\s+)?(\d{1,2}):(\d{2})\b"#, in: text, excluding: excluding),
           let h = capture(m, 1).flatMap(Int.init), let minute = capture(m, 2).flatMap(Int.init), (0...23).contains(h), (0...59).contains(minute) {
            let hour = (h <= 7 && h >= 1) ? h + 12 : h // "at 3:30" → 15:30 ; "at 8:30" → 08:30 ; "15:30" stays.
            return TimeMatch(range: m.range, time: (hour, minute), vague: nil)
        }
        if let m = firstMatch(#"\b(\d{1,2})\s*o'?\s*clock\b"#, in: text, excluding: excluding), let h = capture(m, 1).flatMap(Int.init), (1...12).contains(h) {
            return TimeMatch(range: m.range, time: (Self.assumeMeridiem(h), 0), vague: nil)
        }
        if let m = firstMatch(#"\bat\s+(\d{1,2})\b(?!\s*(?:st|nd|rd|th|/|-|:|\d))"#, in: text, excluding: excluding), let h = capture(m, 1).flatMap(Int.init), (0...23).contains(h) {
            return TimeMatch(range: m.range, time: (Self.assumeMeridiem(h), 0), vague: nil)
        }
        if let m = firstMatch(#"\b(?:in\s+the\s+|this\s+)?(morning|afternoon|evening|night)\b"#, in: text, excluding: excluding) {
            let word = (capture(m, 1) ?? "").lowercased()
            let v: VagueTime = word == "morning" ? .morning : word == "afternoon" ? .afternoon : word == "evening" ? .evening : .night
            return TimeMatch(range: m.range, time: nil, vague: v)
        }
        return nil
    }

    /// Bare hours: 1–7 → PM, 8–11 → AM, 12 → noon, 13–23 as written, 0 → midnight.
    static func assumeMeridiem(_ h: Int) -> Int {
        if (1...7).contains(h) { return h + 12 }
        return h
    }

    private func durationMatch(in text: String, excluding: [Range<String.Index>]) -> DurationMatch? {
        let numberAlternation = "\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|forty-five|sixty|ninety|a couple of|couple of|a few|few|half an|half a"
        let pattern = "\\b(?:in|after|within)\\s+(\(numberAlternation))\\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?)\\b"
        guard let m = firstMatch(pattern, in: text, excluding: excluding) else { return nil }
        let rawNumber = (capture(m, 1) ?? "").lowercased()
        let unit = (capture(m, 2) ?? "").lowercased()
        var value: Int
        if rawNumber.hasPrefix("half") {
            // half an hour → 30 minutes ; half a day → 12 hours
            if unit.hasPrefix("hour") || unit.hasPrefix("hr") { return DurationMatch(range: m.range, component: .minute, value: 30) }
            if unit.hasPrefix("day") { return DurationMatch(range: m.range, component: .hour, value: 12) }
            value = 1
        } else if rawNumber.contains("couple") { value = 2 }
        else if rawNumber.contains("few") { value = 3 }
        else { value = Self.number(from: rawNumber) ?? 1 }
        let component: Calendar.Component
        if unit.hasPrefix("min") { component = .minute }
        else if unit.hasPrefix("hour") || unit.hasPrefix("hr") { component = .hour }
        else if unit.hasPrefix("day") { component = .day }
        else if unit.hasPrefix("week") { component = .weekOfYear }
        else if unit.hasPrefix("month") { component = .month }
        else { component = .year }
        return DurationMatch(range: m.range, component: component, value: value)
    }

    private func firstDateMatch(in text: String, excluding: [Range<String.Index>]) -> DateMatch? {
        let today = calendar.startOfDay(for: now)

        // ISO date anywhere
        if let m = firstMatch(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, in: text, excluding: excluding),
           let y = capture(m, 1).flatMap(Int.init), let mo = capture(m, 2).flatMap(Int.init), let d = capture(m, 3).flatMap(Int.init),
           let date = calendar.date(from: DateComponents(year: y, month: mo, day: d)) {
            return DateMatch(range: m.range, day: calendar.startOfDay(for: date), impliedVague: nil)
        }
        // Relative words
        if let m = firstMatch(#"\b(day after tomorrow|tomorrow|tonight|today|yesterday)\b"#, in: text, excluding: excluding) {
            let word = (capture(m, 1) ?? "").lowercased()
            switch word {
            case "today": return DateMatch(range: m.range, day: today, impliedVague: nil)
            case "tonight": return DateMatch(range: m.range, day: today, impliedVague: .evening)
            case "tomorrow": return DateMatch(range: m.range, day: calendar.date(byAdding: .day, value: 1, to: today) ?? today, impliedVague: nil)
            case "day after tomorrow": return DateMatch(range: m.range, day: calendar.date(byAdding: .day, value: 2, to: today) ?? today, impliedVague: nil)
            case "yesterday": return DateMatch(range: m.range, day: calendar.date(byAdding: .day, value: -1, to: today) ?? today, impliedVague: nil)
            default: break
            }
        }
        // next week / next month / next year / this weekend / end of …
        if let m = firstMatch(#"\bnext\s+(week|month|year)\b"#, in: text, excluding: excluding) {
            let unit = (capture(m, 1) ?? "").lowercased()
            switch unit {
            case "week":
                if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today) {
                    // First working day of next week (Monday when weeks start on Sunday).
                    var day = thisWeek.end
                    if calendar.component(.weekday, from: day) == 1, let mon = calendar.date(byAdding: .day, value: 1, to: day) { day = mon }
                    return DateMatch(range: m.range, day: day, impliedVague: nil)
                }
            case "month":
                if let thisMonth = calendar.dateInterval(of: .month, for: today) { return DateMatch(range: m.range, day: thisMonth.end, impliedVague: nil) }
            default:
                if let thisYear = calendar.dateInterval(of: .year, for: today) { return DateMatch(range: m.range, day: thisYear.end, impliedVague: nil) }
            }
        }
        if let m = firstMatch(#"\b(?:this\s+)?weekend\b"#, in: text, excluding: excluding) {
            // Coming Saturday.
            let day = nextWeekday(7, from: today, includeToday: true)
            return DateMatch(range: m.range, day: day, impliedVague: nil)
        }
        if let m = firstMatch(#"\bend of (?:the\s+)?(day|week|month)\b"#, in: text, excluding: excluding) {
            let unit = (capture(m, 1) ?? "").lowercased()
            switch unit {
            case "day": return DateMatch(range: m.range, day: today, impliedVague: .evening)
            case "week":
                let friday = nextWeekday(6, from: today, includeToday: true)
                return DateMatch(range: m.range, day: friday, impliedVague: .afternoon)
            default:
                if let thisMonth = calendar.dateInterval(of: .month, for: today), let last = calendar.date(byAdding: .day, value: -1, to: thisMonth.end) {
                    return DateMatch(range: m.range, day: last, impliedVague: .morning)
                }
            }
        }
        // Weekday with optional qualifier
        if let m = firstMatch("\\b(next|this|on|coming|this coming)?\\s*\(Self.weekdayPattern)\\b(?!\\s+the\\s+\\d)", in: text, excluding: excluding),
           let name = capture(m, 2)?.lowercased(), let weekday = Self.weekdayNames[name] {
            let qualifier = (capture(m, 1) ?? "").lowercased()
            let coming = nextWeekday(weekday, from: today, includeToday: true)
            var day = coming
            if qualifier == "next" {
                if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today), coming < thisWeek.end {
                    day = calendar.date(byAdding: .day, value: 7, to: coming) ?? coming
                }
            }
            return DateMatch(range: m.range, day: day, impliedVague: nil)
        }
        // Month day (September 11, Sept 11th, 11 September, 11th of September) with optional year
        if let m = firstMatch("\\b\(Self.monthPattern)\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\b", in: text, excluding: excluding),
           let monthName = capture(m, 1)?.lowercased(), let month = Self.monthNames[monthName], let d = capture(m, 2).flatMap(Int.init), (1...31).contains(d) {
            let year = capture(m, 3).flatMap(Int.init)
            return DateMatch(range: m.range, day: resolveMonthDay(month: month, day: d, year: year, today: today), impliedVague: nil)
        }
        if let m = firstMatch("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(Self.monthPattern)\\b(?:,?\\s+(\\d{4}))?", in: text, excluding: excluding),
           let d = capture(m, 1).flatMap(Int.init), let monthName = capture(m, 2)?.lowercased(), let month = Self.monthNames[monthName], (1...31).contains(d) {
            let year = capture(m, 3).flatMap(Int.init)
            return DateMatch(range: m.range, day: resolveMonthDay(month: month, day: d, year: year, today: today), impliedVague: nil)
        }
        // Numeric M/D or M/D/YYYY
        if let m = firstMatch(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, in: text, excluding: excluding),
           let a = capture(m, 1).flatMap(Int.init), let b = capture(m, 2).flatMap(Int.init) {
            var year = capture(m, 3).flatMap(Int.init)
            if let y = year, y < 100 { year = 2000 + y }
            // Follow the locale's month/day ordering when possible; default to month first.
            let monthFirst = Self.prefersMonthFirst(calendar.locale ?? .current)
            let month = monthFirst ? a : b
            let day = monthFirst ? b : a
            if (1...12).contains(month), (1...31).contains(day) {
                return DateMatch(range: m.range, day: resolveMonthDay(month: month, day: day, year: year, today: today), impliedVague: nil)
            }
        }
        // "on the 15th"
        if let m = firstMatch(#"\bon the (\d{1,2})(?:st|nd|rd|th)\b"#, in: text, excluding: excluding), let d = capture(m, 1).flatMap(Int.init), (1...31).contains(d) {
            let month = calendar.component(.month, from: today)
            var date = resolveMonthDay(month: month, day: d, year: nil, today: today)
            if date < today, let next = calendar.date(byAdding: .month, value: 1, to: date) { date = next }
            return DateMatch(range: m.range, day: date, impliedVague: nil)
        }
        return nil
    }

    private func nextWeekday(_ weekday: Int, from today: Date, includeToday: Bool) -> Date {
        let current = calendar.component(.weekday, from: today)
        var delta = (weekday - current + 7) % 7
        if delta == 0 {
            // Same weekday: keep today only if the day isn't already over for practical purposes.
            let endOfDayCutoff = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: today) ?? today
            if !includeToday || now >= endOfDayCutoff { delta = 7 }
        }
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }

    private func resolveMonthDay(month: Int, day: Int, year: Int?, today: Date) -> Date {
        let currentYear = calendar.component(.year, from: today)
        var comps = DateComponents(year: year ?? currentYear, month: month, day: 1)
        guard let firstOfMonth = calendar.date(from: comps) else { return today }
        let maxDay = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        comps.day = min(day, maxDay)
        guard var date = calendar.date(from: comps) else { return today }
        if year == nil, date < today, let nextYear = calendar.date(byAdding: .year, value: 1, to: date) { date = nextYear }
        return calendar.startOfDay(for: date)
    }

    static func prefersMonthFirst(_ locale: Locale) -> Bool {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        let sample = f.string(from: Date(timeIntervalSince1970: 1_700_000_000)) // 2023-11-14
        // If "11" appears before "14" the locale is month-first.
        if let mIdx = sample.range(of: "11"), let dIdx = sample.range(of: "14") { return mIdx.lowerBound < dIdx.lowerBound }
        return true
    }

    static func parseISO(_ text: String, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: trimmed) { return (d, true) }
        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            local.dateFormat = format
            if let d = local.date(from: trimmed) { return (d, hasTime) }
        }
        return nil
    }

    // MARK: Text utilities

    public static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[.!?]+\s*$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remainder(of text: String, removing ranges: [Range<String.Index>]) -> String {
        var s = text
        for r in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            s.replaceSubrange(r, with: " ")
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(at|on|in|for|by|until|till)(\s+the)?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*(at|on|in)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(at|on)\s+(to|that)\b"#, with: " $2", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.")))
    }
}
