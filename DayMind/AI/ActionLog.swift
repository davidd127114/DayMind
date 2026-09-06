import Foundation
import DayMindCore

/// What happens next when the user resolves a choice or confirmation.
enum FollowOn: Equatable, Sendable {
    case complete
    case delete
    case snooze(TimeInterval)
    case reschedule(Date)
    case update(ReminderChanges)
    case followUp(Date)
    case assignProject(String)
}

/// An operation waiting for explicit user confirmation or a choice between candidates.
enum PendingAction: Equatable, Sendable {
    case deleteAllReminders(count: Int)
    case deleteAllMemories(count: Int)
    case createReminderDespiteDuplicate(ReminderDraft, transcript: String?, existing: ReminderSummary)
    case chooseReminder(candidates: [ReminderSummary], then: FollowOn)

    var question: String {
        switch self {
        case .deleteAllReminders(let n): return n == 0 ? "You have no reminders to delete." : "Delete all \(n) reminders? This cannot be undone."
        case .deleteAllMemories(let n): return n == 0 ? "You have no memories to delete." : "Delete all \(n) memories? This cannot be undone."
        case .createReminderDespiteDuplicate(_, _, let existing): return "You already have “\(existing.title)” around then. Add another one anyway?"
        case .chooseReminder(let candidates, _): return "Which one did you mean? I found \(candidates.count) matching reminders."
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteAllReminders, .deleteAllMemories: return true
        default: return false
        }
    }
}

/// A genuine reversal for an action the butler performed. Only recorded where a real undo exists.
enum UndoOperation: Equatable, Sendable {
    /// Undo "create": delete the reminder again.
    case deleteReminder(id: UUID, title: String)
    /// Undo complete / snooze / move: put the reminder back exactly as it was.
    case restoreReminderState(id: UUID, title: String, dueDate: Date?, status: ReminderStatus, completedAt: Date?, followUpDate: Date?, dropLastSnooze: Bool)
    /// Undo delete: recreate from a snapshot.
    case restoreReminder(ReminderSnapshot)
    /// Undo "remember": delete the memory again.
    case deleteMemory(id: UUID, title: String)
    /// Undo memory delete: recreate from a snapshot.
    case restoreMemory(MemorySnapshot)

    var description: String {
        switch self {
        case .deleteReminder(_, let title): return "Removed “\(title)” again."
        case .restoreReminderState(_, let title, _, _, _, _, _): return "“\(title)” is back the way it was."
        case .restoreReminder(let s): return "“\(s.title)” is back."
        case .deleteMemory(_, let title): return "Forgot “\(title)” again."
        case .restoreMemory(let s): return "“\(s.title)” is back."
        }
    }
}

/// One thing the assistant did (or could not do). Rendered as a card and used to compose the
/// spoken confirmation. Only successful tool calls create success records.
struct ActionRecord: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case reminderCreated(ReminderSummary)
        case reminderUpdated(ReminderSummary, change: String)
        case reminderCompleted(ReminderSummary, nextOccurrence: Date?)
        case reminderDeleted(title: String)
        case reminderSnoozed(ReminderSummary, until: Date)
        case reminderFollowUpSet(ReminderSummary, at: Date)
        case remindersDeleted(count: Int)
        case remindersListed([ReminderSummary], scope: ReminderListScope)
        case memorySaved(MemorySummary)
        case memoryUpdated(MemorySummary, change: String)
        case memoryDeleted(title: String)
        case memoriesDeleted(count: Int)
        case memoriesFound([MemorySummary], query: String)
        case projectCreated(name: String)
        case itemAssignedToProject(itemTitle: String, project: String)
        case briefing(String)
        case needsConfirmation(PendingAction)
        case needsChoice(PendingAction)
        case needsClarification(question: String)
        case notFound(what: String)
        case failed(operation: String, message: String)
        case savedToInbox(reason: InboxReason)
        case undone(String)
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date

    init(_ kind: Kind) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = Date()
    }

    /// Same identity, refreshed content (used when a card's summary is updated after an edit).
    init(id: UUID, kind: Kind, timestamp: Date) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }

    /// True when the database changed as a result of this action.
    var changedData: Bool {
        switch kind {
        case .reminderCreated, .reminderUpdated, .reminderCompleted, .reminderDeleted, .reminderSnoozed, .reminderFollowUpSet,
             .remindersDeleted, .memorySaved, .memoryUpdated, .memoryDeleted, .memoriesDeleted, .projectCreated, .itemAssignedToProject, .undone:
            return true
        default:
            return false
        }
    }

    var isProblem: Bool {
        switch kind {
        case .failed, .notFound, .savedToInbox: return true
        default: return false
        }
    }

    /// The reminder this record is about, if any (for Edit / Done controls on the card).
    var reminderID: UUID? {
        switch kind {
        case .reminderCreated(let r), .reminderUpdated(let r, _), .reminderCompleted(let r, _), .reminderSnoozed(let r, _), .reminderFollowUpSet(let r, _): return r.id
        default: return nil
        }
    }

    var memoryID: UUID? {
        switch kind {
        case .memorySaved(let m), .memoryUpdated(let m, _): return m.id
        default: return nil
        }
    }
}

/// Collects action records during one request. Tools write here; the engine reads it afterwards.
@MainActor
final class ActionLog {
    private(set) var records: [ActionRecord] = []
    private(set) var pending: PendingAction?
    /// Undo operations keyed by the record they reverse.
    private(set) var undoOperations: [UUID: UndoOperation] = [:]

    @discardableResult
    func record(_ kind: ActionRecord.Kind, undo: UndoOperation? = nil) -> ActionRecord {
        let record = ActionRecord(kind)
        records.append(record)
        if let undo { undoOperations[record.id] = undo }
        switch kind {
        case .needsConfirmation(let p), .needsChoice(let p): pending = p
        default: break
        }
        return record
    }

    func reset() {
        records = []
        pending = nil
        undoOperations = [:]
    }

    var changedData: Bool { records.contains { $0.changedData } }
    var hasProblems: Bool { records.contains { $0.isProblem } }
}
