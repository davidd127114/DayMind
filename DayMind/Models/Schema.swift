import Foundation
import SwiftData
import DayMindCore

// MARK: - Versioned schema
//
// Rules followed so the store stays CloudKit-compatible:
//  • every stored property has a default value or is optional
//  • no `@Attribute(.unique)` constraints (uniqueness is enforced in the services)
//  • all relationships are optional
// Complex values (recurrence rules, histories) are stored as JSON `Data` blobs so they survive
// migrations and sync without custom transformers.

enum DayMindSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Reminder.self, Memory.self, Person.self, Project.self, ConversationTurn.self, InboxItem.self, UserPreferences.self, BriefingSettings.self]
    }

    @Model
    final class Reminder {
        var id: UUID = UUID()
        var title: String = ""
        var notes: String = ""
        var createdAt: Date = Date()
        var dueDate: Date?
        var timeZoneIdentifier: String = TimeZone.current.identifier
        var recurrenceData: Data?
        var priorityRaw: String = ReminderPriority.normal.rawValue
        var statusRaw: String = ReminderStatus.pending.rawValue
        var completedAt: Date?
        var snoozeHistoryData: Data?
        var missedOccurrencesData: Data?
        var notificationIdentifier: String?
        /// Optional second notification ("remind me again tomorrow if I don't complete this").
        var followUpDate: Date?
        var relatedMemoryIDsData: Data?
        var originalTranscript: String?
        var lastModified: Date = Date()

        @Relationship(deleteRule: .nullify, inverse: \Person.reminders)
        var people: [Person]?

        @Relationship(deleteRule: .nullify, inverse: \Project.reminders)
        var project: Project?

        init(title: String, notes: String = "", dueDate: Date? = nil, timeZoneIdentifier: String = TimeZone.current.identifier,
             recurrence: RecurrenceRule? = nil, priority: ReminderPriority = .normal, originalTranscript: String? = nil) {
            self.id = UUID()
            self.title = title
            self.notes = notes
            self.createdAt = Date()
            self.dueDate = dueDate
            self.timeZoneIdentifier = timeZoneIdentifier
            self.recurrenceData = recurrence.flatMap { DayMindJSON.encode($0) }
            self.priorityRaw = priority.rawValue
            self.statusRaw = ReminderStatus.pending.rawValue
            self.originalTranscript = originalTranscript
            self.lastModified = Date()
        }
    }

    @Model
    final class Memory {
        var id: UUID = UUID()
        var title: String = ""
        var content: String = ""
        var categoryRaw: String = MemoryCategory.fact.rawValue
        var tags: [String] = []
        var importanceRaw: String = Importance.normal.rawValue
        var createdAt: Date = Date()
        var lastAccessedAt: Date?
        var originalTranscript: String?
        var isArchived: Bool = false
        var lastModified: Date = Date()

        @Relationship(deleteRule: .nullify, inverse: \Person.memories)
        var people: [Person]?

        @Relationship(deleteRule: .nullify, inverse: \Project.memories)
        var project: Project?

        init(title: String, content: String, category: MemoryCategory = .fact, tags: [String] = [], importance: Importance = .normal, originalTranscript: String? = nil) {
            self.id = UUID()
            self.title = title
            self.content = content
            self.categoryRaw = category.rawValue
            self.tags = tags
            self.importanceRaw = importance.rawValue
            self.createdAt = Date()
            self.originalTranscript = originalTranscript
            self.lastModified = Date()
        }
    }

    @Model
    final class Person {
        var id: UUID = UUID()
        var name: String = ""
        var notes: String = ""
        var createdAt: Date = Date()
        var reminders: [Reminder]?
        var memories: [Memory]?

        init(name: String, notes: String = "") {
            self.id = UUID()
            self.name = name
            self.notes = notes
            self.createdAt = Date()
        }
    }

    @Model
    final class Project {
        var id: UUID = UUID()
        var name: String = ""
        var summary: String = ""
        var colorName: String = "blue"
        var createdAt: Date = Date()
        var isArchived: Bool = false
        var reminders: [Reminder]?
        var memories: [Memory]?

        init(name: String, summary: String = "", colorName: String = "blue") {
            self.id = UUID()
            self.name = name
            self.summary = summary
            self.colorName = colorName
            self.createdAt = Date()
        }
    }

    @Model
    final class ConversationTurn {
        var id: UUID = UUID()
        var roleRaw: String = ConversationRole.user.rawValue
        var text: String = ""
        var timestamp: Date = Date()
        var actionSummary: String?

        init(role: ConversationRole, text: String, actionSummary: String? = nil) {
            self.id = UUID()
            self.roleRaw = role.rawValue
            self.text = text
            self.timestamp = Date()
            self.actionSummary = actionSummary
        }
    }

    @Model
    final class InboxItem {
        var id: UUID = UUID()
        var text: String = ""
        var capturedAt: Date = Date()
        var sourceRaw: String = CaptureSource.text.rawValue
        var reasonRaw: String = InboxReason.modelUnavailable.rawValue
        var detail: String?
        var retryCount: Int = 0
        var isResolved: Bool = false

        init(text: String, source: CaptureSource, reason: InboxReason, detail: String? = nil) {
            self.id = UUID()
            self.text = text
            self.capturedAt = Date()
            self.sourceRaw = source.rawValue
            self.reasonRaw = reason.rawValue
            self.detail = detail
        }
    }

    /// Mirrors `SettingsStore` so preferences can sync through CloudKit. Exactly one row is kept.
    @Model
    final class UserPreferences {
        var id: UUID = UUID()
        var timeZoneIdentifier: String?
        var morningMinutes: Int = 9 * 60
        var afternoonMinutes: Int = 14 * 60
        var eveningMinutes: Int = 18 * 60
        var nightMinutes: Int = 20 * 60
        var transcriptRetentionRaw: String = TranscriptRetention.thirtyDays.rawValue
        var voiceIdentifier: String?
        var speechRate: Double = 0.5
        var speakResponses: Bool = true
        var lastModified: Date = Date()

        init() {}
    }

    @Model
    final class BriefingSettings {
        var id: UUID = UUID()
        var isEnabled: Bool = false
        var minutesFromMidnight: Int = 8 * 60
        var includeInbox: Bool = true
        var includeProjectNotes: Bool = true
        var lastModified: Date = Date()

        init() {}
    }
}

typealias Reminder = DayMindSchemaV1.Reminder
typealias Memory = DayMindSchemaV1.Memory
typealias Person = DayMindSchemaV1.Person
typealias Project = DayMindSchemaV1.Project
typealias ConversationTurn = DayMindSchemaV1.ConversationTurn
typealias InboxItem = DayMindSchemaV1.InboxItem
typealias UserPreferences = DayMindSchemaV1.UserPreferences
typealias BriefingSettings = DayMindSchemaV1.BriefingSettings

enum DayMindMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [DayMindSchemaV1.self] }
    // Future versions append `.lightweight(fromVersion: DayMindSchemaV1.self, toVersion: DayMindSchemaV2.self)` here.
    static var stages: [MigrationStage] { [] }
}
