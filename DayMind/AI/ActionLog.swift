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
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date

    init(_ kind: Kind) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = Date()
    }

    /// True when the database changed as a result of this action.
    var changedData: Bool {
        switch kind {
        case .reminderCreated, .reminderUpdated, .reminderCompleted, .reminderDeleted, .reminderSnoozed, .reminderFollowUpSet,
             .remindersDeleted, .memorySaved, .memoryUpdated, .memoryDeleted, .memoriesDeleted, .projectCreated, .itemAssignedToProject:
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
}

/// Collects action records during one request. Tools write here; the engine reads it afterwards.
@MainActor
final class ActionLog {
    private(set) var records: [ActionRecord] = []
    private(set) var pending: PendingAction?

    func record(_ kind: ActionRecord.Kind) {
        records.append(ActionRecord(kind))
        switch kind {
        case .needsConfirmation(let p), .needsChoice(let p): pending = p
        default: break
        }
    }

    func reset() {
        records = []
        pending = nil
    }

    var changedData: Bool { records.contains { $0.changedData } }
    var hasProblems: Bool { records.contains { $0.isProblem } }
}
