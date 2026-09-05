import Foundation
import SwiftData
import DayMindCore

extension Reminder {
    var priority: ReminderPriority {
        get { ReminderPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var status: ReminderStatus {
        get { ReminderStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceRule? {
        get { DayMindJSON.decode(RecurrenceRule.self, from: recurrenceData) }
        set { recurrenceData = newValue.flatMap { DayMindJSON.encode($0) } }
    }

    var snoozeHistory: [SnoozeEvent] {
        get { DayMindJSON.decode([SnoozeEvent].self, from: snoozeHistoryData) ?? [] }
        set { snoozeHistoryData = DayMindJSON.encode(newValue) }
    }

    var missedOccurrences: [MissedOccurrence] {
        get { DayMindJSON.decode([MissedOccurrence].self, from: missedOccurrencesData) ?? [] }
        set { missedOccurrencesData = DayMindJSON.encode(newValue) }
    }

    var relatedMemoryIDs: [UUID] {
        get { DayMindJSON.decode([UUID].self, from: relatedMemoryIDsData) ?? [] }
        set { relatedMemoryIDsData = DayMindJSON.encode(newValue) }
    }

    var isPending: Bool { status == .pending }
    var isRecurring: Bool { recurrence != nil }

    func isOverdue(now: Date) -> Bool {
        guard isPending, let dueDate else { return false }
        return dueDate < now
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The identifier used for this reminder's notification request.
    var notificationRequestIdentifier: String { "reminder-\(id.uuidString)" }
    var followUpNotificationIdentifier: String { "reminder-\(id.uuidString)-followup" }

    var peopleNames: [String] { (people ?? []).map(\.name).sorted() }

    func touch() { lastModified = Date() }
}

extension Memory {
    var category: MemoryCategory {
        get { MemoryCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var importance: Importance {
        get { Importance(rawValue: importanceRaw) ?? .normal }
        set { importanceRaw = newValue.rawValue }
    }

    var peopleNames: [String] { (people ?? []).map(\.name).sorted() }

    func touch() { lastModified = Date() }
}

extension ConversationTurn {
    var role: ConversationRole { ConversationRole(rawValue: roleRaw) ?? .user }
}

extension InboxItem {
    var source: CaptureSource { CaptureSource(rawValue: sourceRaw) ?? .text }
    var reason: InboxReason {
        get { InboxReason(rawValue: reasonRaw) ?? .modelUnavailable }
        set { reasonRaw = newValue.rawValue }
    }
}

extension UserPreferences {
    var timeDefaults: TimeDefaults {
        get {
            TimeDefaults(morning: TimeOfDay(hour: morningMinutes / 60, minute: morningMinutes % 60),
                         afternoon: TimeOfDay(hour: afternoonMinutes / 60, minute: afternoonMinutes % 60),
                         evening: TimeOfDay(hour: eveningMinutes / 60, minute: eveningMinutes % 60),
                         night: TimeOfDay(hour: nightMinutes / 60, minute: nightMinutes % 60))
        }
        set {
            morningMinutes = newValue.morning.totalMinutes
            afternoonMinutes = newValue.afternoon.totalMinutes
            eveningMinutes = newValue.evening.totalMinutes
            nightMinutes = newValue.night.totalMinutes
        }
    }

    var transcriptRetention: TranscriptRetention {
        get { TranscriptRetention(rawValue: transcriptRetentionRaw) ?? .thirtyDays }
        set { transcriptRetentionRaw = newValue.rawValue }
    }
}

extension BriefingSettings {
    var time: TimeOfDay {
        get { TimeOfDay(hour: minutesFromMidnight / 60, minute: minutesFromMidnight % 60) }
        set { minutesFromMidnight = newValue.totalMinutes }
    }
}

// MARK: - Lightweight, Sendable summaries used by the AI layer and the UI cards.

struct ReminderSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var dueDate: Date?
    var recurrenceText: String?
    var status: ReminderStatus
    var priority: ReminderPriority
    var people: [String]
    var projectName: String?
    var scheduleStatus: ScheduleStatus

    init(_ r: Reminder, calendar: Calendar, scheduleStatus: ScheduleStatus = .unknown) {
        self.scheduleStatus = scheduleStatus
        id = r.id
        title = r.title
        notes = r.notes
        dueDate = r.dueDate
        recurrenceText = r.recurrence?.humanDescription(anchor: r.dueDate, calendar: calendar)
        status = r.status
        priority = r.priority
        people = r.peopleNames
        projectName = r.project?.name
    }

    func phrase(now: Date, calendar: Calendar) -> String {
        guard let dueDate else { return title }
        return "\(title) — \(SpokenFormatter.dateTimePhrase(dueDate, now: now, calendar: calendar))"
    }
}

struct MemorySummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var content: String
    var category: MemoryCategory
    var people: [String]
    var projectName: String?
    var tags: [String]
    var createdAt: Date

    init(_ m: Memory) {
        id = m.id
        title = m.title
        content = m.content
        category = m.category
        people = m.peopleNames
        projectName = m.project?.name
        tags = m.tags
        createdAt = m.createdAt
    }
}
