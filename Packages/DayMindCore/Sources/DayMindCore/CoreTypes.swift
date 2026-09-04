import Foundation

// MARK: - Enumerations shared by the app, the AI tools and the export format.

public enum ReminderPriority: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case low, normal, high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    public var sortWeight: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }
}

public enum ReminderStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case pending, completed

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .completed: return "Completed"
        }
    }
}

public enum MemoryCategory: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case fact, preference, decision, person, project, idea, health, place, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .decision: return "Decision"
        case .person: return "Person"
        case .project: return "Project"
        case .idea: return "Idea"
        case .health: return "Health"
        case .place: return "Place"
        case .other: return "Other"
        }
    }

    public var systemImageName: String {
        switch self {
        case .fact: return "info.circle"
        case .preference: return "heart.text.square"
        case .decision: return "checkmark.seal"
        case .person: return "person"
        case .project: return "folder"
        case .idea: return "lightbulb"
        case .health: return "cross.case"
        case .place: return "mappin.and.ellipse"
        case .other: return "note.text"
        }
    }
}

public enum Importance: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case low, normal, high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// How long the app keeps the raw text of what the user said.
public enum TranscriptRetention: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case never, sevenDays, thirtyDays, forever

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .never: return "Do not keep transcripts"
        case .sevenDays: return "Keep for 7 days"
        case .thirtyDays: return "Keep for 30 days"
        case .forever: return "Keep until deleted"
        }
    }

    /// Number of days to keep transcripts. `nil` means forever; `0` means do not keep.
    public var retentionDays: Int? {
        switch self {
        case .never: return 0
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .forever: return nil
        }
    }
}

public struct SnoozeEvent: Codable, Equatable, Sendable, Hashable {
    public var snoozedAt: Date
    public var previousDueDate: Date?
    public var newDueDate: Date

    public init(snoozedAt: Date, previousDueDate: Date?, newDueDate: Date) {
        self.snoozedAt = snoozedAt
        self.previousDueDate = previousDueDate
        self.newDueDate = newDueDate
    }
}

/// A recurring reminder occurrence that passed without being completed.
public struct MissedOccurrence: Codable, Equatable, Sendable, Hashable {
    public var dueDate: Date
    public var recordedAt: Date

    public init(dueDate: Date, recordedAt: Date) {
        self.dueDate = dueDate
        self.recordedAt = recordedAt
    }
}

/// Where an inbox item came from.
public enum CaptureSource: String, Codable, CaseIterable, Sendable, Hashable {
    case voice, text, shortcut, notificationAction
}

/// Why a capture ended up in the Unprocessed Inbox.
public enum InboxReason: String, Codable, CaseIterable, Sendable, Hashable {
    case modelUnavailable
    case modelFailed
    case toolFailed
    case speechFailed
    case userDeferred
    case ambiguous

    public var displayName: String {
        switch self {
        case .modelUnavailable: return "Apple Intelligence was unavailable"
        case .modelFailed: return "The on-device model could not process it"
        case .toolFailed: return "Saving failed"
        case .speechFailed: return "Speech recognition was interrupted"
        case .userDeferred: return "Saved for later"
        case .ambiguous: return "Needs clarification"
        }
    }
}

public enum ConversationRole: String, Codable, CaseIterable, Sendable, Hashable {
    case user, assistant, system
}

/// Shared JSON coding helpers (ISO-8601 dates, sorted keys) used by the app and the export format.
public enum DayMindJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder().decode(type, from: data)
    }
}
