import Foundation

// Versioned JSON export/import format. Independent of SwiftData so backups survive schema changes.

public struct ReminderDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var createdAt: Date
    public var dueDate: Date?
    public var timeZoneIdentifier: String
    public var recurrence: RecurrenceRule?
    public var priority: ReminderPriority
    public var status: ReminderStatus
    public var completedAt: Date?
    public var snoozeHistory: [SnoozeEvent]
    public var missedOccurrences: [MissedOccurrence]
    public var notificationIdentifier: String?
    public var peopleIDs: [UUID]
    public var projectID: UUID?
    public var relatedMemoryIDs: [UUID]
    public var originalTranscript: String?
    public var lastModified: Date
    public var repeatIfIncomplete: Bool

    public init(id: UUID, title: String, notes: String, createdAt: Date, dueDate: Date?, timeZoneIdentifier: String, recurrence: RecurrenceRule?, priority: ReminderPriority, status: ReminderStatus, completedAt: Date?, snoozeHistory: [SnoozeEvent], missedOccurrences: [MissedOccurrence], notificationIdentifier: String?, peopleIDs: [UUID], projectID: UUID?, relatedMemoryIDs: [UUID], originalTranscript: String?, lastModified: Date, repeatIfIncomplete: Bool) {
        self.id = id; self.title = title; self.notes = notes; self.createdAt = createdAt; self.dueDate = dueDate
        self.timeZoneIdentifier = timeZoneIdentifier; self.recurrence = recurrence; self.priority = priority; self.status = status
        self.completedAt = completedAt; self.snoozeHistory = snoozeHistory; self.missedOccurrences = missedOccurrences
        self.notificationIdentifier = notificationIdentifier; self.peopleIDs = peopleIDs; self.projectID = projectID
        self.relatedMemoryIDs = relatedMemoryIDs; self.originalTranscript = originalTranscript; self.lastModified = lastModified
        self.repeatIfIncomplete = repeatIfIncomplete
    }
}

public struct MemoryDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var content: String
    public var category: MemoryCategory
    public var peopleIDs: [UUID]
    public var projectID: UUID?
    public var tags: [String]
    public var importance: Importance
    public var createdAt: Date
    public var lastAccessedAt: Date?
    public var originalTranscript: String?
    public var isArchived: Bool
    public var lastModified: Date

    public init(id: UUID, title: String, content: String, category: MemoryCategory, peopleIDs: [UUID], projectID: UUID?, tags: [String], importance: Importance, createdAt: Date, lastAccessedAt: Date?, originalTranscript: String?, isArchived: Bool, lastModified: Date) {
        self.id = id; self.title = title; self.content = content; self.category = category; self.peopleIDs = peopleIDs
        self.projectID = projectID; self.tags = tags; self.importance = importance; self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt; self.originalTranscript = originalTranscript; self.isArchived = isArchived; self.lastModified = lastModified
    }
}

public struct PersonDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var createdAt: Date
    public init(id: UUID, name: String, notes: String, createdAt: Date) {
        self.id = id; self.name = name; self.notes = notes; self.createdAt = createdAt
    }
}

public struct ProjectDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var colorName: String
    public var createdAt: Date
    public var isArchived: Bool
    public init(id: UUID, name: String, summary: String, colorName: String, createdAt: Date, isArchived: Bool) {
        self.id = id; self.name = name; self.summary = summary; self.colorName = colorName; self.createdAt = createdAt; self.isArchived = isArchived
    }
}

public struct InboxItemDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var capturedAt: Date
    public var source: CaptureSource
    public var reason: InboxReason
    public var detail: String?
    public var retryCount: Int
    public init(id: UUID, text: String, capturedAt: Date, source: CaptureSource, reason: InboxReason, detail: String?, retryCount: Int) {
        self.id = id; self.text = text; self.capturedAt = capturedAt; self.source = source; self.reason = reason; self.detail = detail; self.retryCount = retryCount
    }
}

public struct ConversationTurnDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var role: ConversationRole
    public var text: String
    public var timestamp: Date
    public var actionSummary: String?
    public init(id: UUID, role: ConversationRole, text: String, timestamp: Date, actionSummary: String?) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp; self.actionSummary = actionSummary
    }
}

public struct PreferencesDTO: Codable, Equatable, Sendable {
    public var timeZoneIdentifier: String?
    public var timeDefaults: TimeDefaults
    public var briefingEnabled: Bool
    public var briefingTime: TimeOfDay
    public var transcriptRetention: TranscriptRetention
    public var voiceIdentifier: String?
    public var speechRate: Double
    public init(timeZoneIdentifier: String?, timeDefaults: TimeDefaults, briefingEnabled: Bool, briefingTime: TimeOfDay, transcriptRetention: TranscriptRetention, voiceIdentifier: String?, speechRate: Double) {
        self.timeZoneIdentifier = timeZoneIdentifier; self.timeDefaults = timeDefaults; self.briefingEnabled = briefingEnabled
        self.briefingTime = briefingTime; self.transcriptRetention = transcriptRetention; self.voiceIdentifier = voiceIdentifier; self.speechRate = speechRate
    }
}

public struct ExportDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var reminders: [ReminderDTO]
    public var memories: [MemoryDTO]
    public var people: [PersonDTO]
    public var projects: [ProjectDTO]
    public var inbox: [InboxItemDTO]
    public var conversation: [ConversationTurnDTO]
    public var preferences: PreferencesDTO?

    public init(exportedAt: Date, appVersion: String, reminders: [ReminderDTO], memories: [MemoryDTO], people: [PersonDTO], projects: [ProjectDTO], inbox: [InboxItemDTO], conversation: [ConversationTurnDTO], preferences: PreferencesDTO?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt; self.appVersion = appVersion; self.reminders = reminders; self.memories = memories
        self.people = people; self.projects = projects; self.inbox = inbox; self.conversation = conversation; self.preferences = preferences
    }

    public func encoded() throws -> Data {
        try DayMindJSON.encoder(pretty: true).encode(self)
    }

    public static func decode(_ data: Data) throws -> ExportDocument {
        let doc = try DayMindJSON.decoder().decode(ExportDocument.self, from: data)
        guard doc.schemaVersion <= currentSchemaVersion else {
            throw ExportError.newerSchema(doc.schemaVersion)
        }
        return doc
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case newerSchema(Int)
        public var errorDescription: String? {
            switch self {
            case .newerSchema(let v): return "This backup was made by a newer version of DayMind (format \(v)). Update the app to import it."
            }
        }
    }
}
