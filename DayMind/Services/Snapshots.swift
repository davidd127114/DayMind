import Foundation
import SwiftData
import DayMindCore

/// Value copies used to undo deletions and to restore reminders/memories exactly as they were.

struct ReminderSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var notes: String
    var createdAt: Date
    var dueDate: Date?
    var timeZoneIdentifier: String
    var recurrence: RecurrenceRule?
    var priority: ReminderPriority
    var status: ReminderStatus
    var completedAt: Date?
    var snoozeHistory: [SnoozeEvent]
    var missedOccurrences: [MissedOccurrence]
    var followUpDate: Date?
    var relatedMemoryIDs: [UUID]
    var originalTranscript: String?
    var people: [String]
    var projectName: String?
}

struct MemorySnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var content: String
    var category: MemoryCategory
    var tags: [String]
    var importance: Importance
    var createdAt: Date
    var lastAccessedAt: Date?
    var originalTranscript: String?
    var isArchived: Bool
    var people: [String]
    var projectName: String?
}

extension ReminderService {
    func snapshot(_ r: Reminder) -> ReminderSnapshot {
        ReminderSnapshot(id: r.id, title: r.title, notes: r.notes, createdAt: r.createdAt, dueDate: r.dueDate, timeZoneIdentifier: r.timeZoneIdentifier,
                         recurrence: r.recurrence, priority: r.priority, status: r.status, completedAt: r.completedAt, snoozeHistory: r.snoozeHistory,
                         missedOccurrences: r.missedOccurrences, followUpDate: r.followUpDate, relatedMemoryIDs: r.relatedMemoryIDs,
                         originalTranscript: r.originalTranscript, people: r.peopleNames, projectName: r.project?.name)
    }

    /// Recreates a deleted reminder (same identifier) and reschedules its alert.
    @discardableResult
    func restore(_ s: ReminderSnapshot) async throws -> Reminder {
        if let existing = fetch(id: s.id) { return existing }
        let r = Reminder(title: s.title, notes: s.notes, dueDate: s.dueDate, timeZoneIdentifier: s.timeZoneIdentifier,
                         recurrence: s.recurrence, priority: s.priority, originalTranscript: s.originalTranscript)
        r.id = s.id
        r.createdAt = s.createdAt
        r.status = s.status
        r.completedAt = s.completedAt
        r.snoozeHistory = s.snoozeHistory
        r.missedOccurrences = s.missedOccurrences
        r.followUpDate = s.followUpDate
        r.relatedMemoryIDs = s.relatedMemoryIDs
        r.people = s.people.map { peopleService.findOrCreate(name: $0) }
        if let name = s.projectName { r.project = projectService.findOrCreate(name: name) }
        store.context.insert(r)
        try store.save()
        await resync(r)
        return r
    }

    /// Puts a reminder back to an earlier due date / status (undo for snooze, move and complete).
    func restore(_ r: Reminder, dueDate: Date?, status: ReminderStatus, completedAt: Date?, followUpDate: Date?, dropLastSnooze: Bool) async throws {
        r.dueDate = dueDate
        r.status = status
        r.completedAt = completedAt
        r.followUpDate = followUpDate
        if dropLastSnooze, !r.snoozeHistory.isEmpty {
            var history = r.snoozeHistory
            history.removeLast()
            r.snoozeHistory = history
        }
        r.touch()
        try store.save()
        await resync(r)
    }
}

extension MemoryService {
    func snapshot(_ m: Memory) -> MemorySnapshot {
        MemorySnapshot(id: m.id, title: m.title, content: m.content, category: m.category, tags: m.tags, importance: m.importance,
                       createdAt: m.createdAt, lastAccessedAt: m.lastAccessedAt, originalTranscript: m.originalTranscript, isArchived: m.isArchived,
                       people: m.peopleNames, projectName: m.project?.name)
    }

    @discardableResult
    func restore(_ s: MemorySnapshot) throws -> Memory {
        if let existing = fetch(id: s.id) { return existing }
        let m = Memory(title: s.title, content: s.content, category: s.category, tags: s.tags, importance: s.importance, originalTranscript: s.originalTranscript)
        m.id = s.id
        m.createdAt = s.createdAt
        m.lastAccessedAt = s.lastAccessedAt
        m.isArchived = s.isArchived
        m.people = s.people.map { peopleService.findOrCreate(name: $0) }
        if let name = s.projectName { m.project = projectService.findOrCreate(name: name) }
        storeRef.context.insert(m)
        try storeRef.save()
        return m
    }
}
