import Foundation

/// Produces the exact wording used in confirmations, e.g. "Friday, September 11 at 10:00 AM".
public enum SpokenFormatter {
    public static func timeString(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.timeStyle = .short
        f.dateStyle = .none
        // Foundation inserts a narrow no-break space before AM/PM; use a plain space so the text
        // reads and speaks naturally and compares predictably.
        return f.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    public static func longDayString(_ date: Date, calendar: Calendar, locale: Locale = .current, includeYear: Bool = false) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(includeYear ? "EEEEMMMMdyyyy" : "EEEEMMMMd")
        return f.string(from: date)
    }

    /// "today", "tomorrow", "yesterday", or a long weekday/month/day string. Adds the year when it differs.
    public static func relativeDayName(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return longDayString(date, calendar: calendar, locale: locale, includeYear: !sameYear)
    }

    /// "tomorrow at 3:00 PM" / "Friday, September 11 at 10:00 AM".
    public static func dateTimePhrase(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current, includeTime: Bool = true) -> String {
        let day = relativeDayName(date, now: now, calendar: calendar, locale: locale)
        guard includeTime else { return day }
        return "\(day) at \(timeString(date, calendar: calendar, locale: locale))"
    }

    /// Wording for a completed create/reschedule: "Done. I'll remind you Friday, September 11 at 10:00 AM."
    public static func reminderConfirmation(title: String, date: Date?, recurrence: RecurrenceRule?, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        guard let date else {
            return "Done. I saved \"\(title)\" with no due date."
        }
        let when = dateTimePhrase(date, now: now, calendar: calendar, locale: locale)
        if let recurrence {
            let rule = recurrence.humanDescription(anchor: date, calendar: calendar, locale: locale)
            return "Done. I'll remind you to \(lowercaseFirst(title)) \(rule), starting \(when)."
        }
        return "Done. I'll remind you to \(lowercaseFirst(title)) \(when)."
    }

    public static func durationPhrase(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        if total % 86_400 == 0 { let d = total / 86_400; return d == 1 ? "1 day" : "\(d) days" }
        if total % 3_600 == 0 { let h = total / 3_600; return h == 1 ? "1 hour" : "\(h) hours" }
        let m = max(1, total / 60)
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    public static func lowercaseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        // Keep proper nouns that are already capitalised beyond the first word untouched.
        let rest = s.dropFirst()
        let firstWord = s.split(separator: " ").first.map(String.init) ?? s
        if firstWord.count > 1, firstWord == firstWord.uppercased() { return s } // acronym like "PDF"
        return String(first).lowercased() + rest
    }

    public static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
