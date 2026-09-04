import Foundation

public struct BriefingItem: Equatable, Sendable {
    public var title: String
    public var dueDate: Date?
    public var priority: ReminderPriority
    public init(title: String, dueDate: Date?, priority: ReminderPriority = .normal) {
        self.title = title
        self.dueDate = dueDate
        self.priority = priority
    }
}

public struct BriefingInput: Equatable, Sendable {
    public var now: Date
    public var today: [BriefingItem]
    public var overdue: [BriefingItem]
    public var upcoming: [BriefingItem]
    public var inboxCount: Int
    public var projectNotes: [String]

    public init(now: Date, today: [BriefingItem], overdue: [BriefingItem], upcoming: [BriefingItem], inboxCount: Int, projectNotes: [String] = []) {
        self.now = now
        self.today = today
        self.overdue = overdue
        self.upcoming = upcoming
        self.inboxCount = inboxCount
        self.projectNotes = projectNotes
    }
}

/// Builds the short, actionable daily briefing without any AI.
public struct BriefingComposer: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.calendar = calendar
        self.locale = locale
    }

    /// One-line headline suitable for a notification title.
    public func headline(_ input: BriefingInput) -> String {
        let count = input.today.count
        if input.overdue.isEmpty && count == 0 { return "Nothing scheduled today" }
        var parts: [String] = []
        if count > 0 { parts.append("\(count) today") }
        if !input.overdue.isEmpty { parts.append("\(input.overdue.count) overdue") }
        return parts.joined(separator: " · ")
    }

    /// Spoken / notification body. Kept under roughly six sentences.
    public func compose(_ input: BriefingInput, maxItems: Int = 4) -> String {
        var sentences: [String] = []
        let dayName = SpokenFormatter.longDayString(input.now, calendar: calendar, locale: locale)
        if input.today.isEmpty && input.overdue.isEmpty {
            sentences.append("Good \(partOfDay(input.now)). It's \(dayName) and you have nothing scheduled today.")
        } else {
            sentences.append("Good \(partOfDay(input.now)). It's \(dayName).")
        }
        if !input.overdue.isEmpty {
            let names = input.overdue.prefix(maxItems).map { "\"\($0.title)\"" }
            let extra = input.overdue.count > maxItems ? " and \(input.overdue.count - maxItems) more" : ""
            sentences.append(input.overdue.count == 1 ? "One reminder is overdue: \(names[0])." : "\(input.overdue.count) reminders are overdue: \(RecurrenceRule.joinList(Array(names)))\(extra).")
        }
        if !input.today.isEmpty {
            let items = input.today.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            let described = items.prefix(maxItems).map { item -> String in
                if let due = item.dueDate { return "\(item.title) at \(SpokenFormatter.timeString(due, calendar: calendar, locale: locale))" }
                return item.title
            }
            let extra = items.count > maxItems ? ", plus \(items.count - maxItems) more" : ""
            sentences.append(items.count == 1 ? "Today: \(described[0])." : "Today you have \(items.count) reminders: \(RecurrenceRule.joinList(Array(described)))\(extra).")
        }
        let important = input.upcoming.filter { $0.priority == .high }.prefix(2)
        if !important.isEmpty {
            let described = important.map { item -> String in
                if let due = item.dueDate { return "\(item.title) \(SpokenFormatter.dateTimePhrase(due, now: input.now, calendar: calendar, locale: locale, includeTime: false))" }
                return item.title
            }
            sentences.append("Coming up: \(RecurrenceRule.joinList(Array(described))).")
        } else if let next = input.upcoming.first, let due = next.dueDate {
            sentences.append("Next up: \(next.title) \(SpokenFormatter.dateTimePhrase(due, now: input.now, calendar: calendar, locale: locale)).")
        }
        if input.inboxCount > 0 {
            sentences.append(input.inboxCount == 1 ? "One capture in your Inbox still needs review." : "\(input.inboxCount) captures in your Inbox still need review.")
        }
        if let note = input.projectNotes.first {
            sentences.append("Project note: \(note)")
        }
        return sentences.joined(separator: " ")
    }

    func partOfDay(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        if hour < 12 { return "morning" }
        if hour < 17 { return "afternoon" }
        return "evening"
    }
}
