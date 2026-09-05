import Foundation
import Observation
import os
import DayMindCore

enum AssistantMode: String, Sendable {
    case appleIntelligence
    case deterministic

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .deterministic: return "Offline rules"
        }
    }
}

/// What the Talk screen renders after one request.
struct AssistantResult: Equatable, Sendable, Identifiable {
    let id = UUID()
    var responseText: String
    var actions: [ActionRecord]
    var mode: AssistantMode
    var pending: PendingAction?
    /// Pre-filled drafts offered when the request could not be completed automatically.
    var suggestedReminder: ReminderDraft?
    var suggestedMemory: MemoryDraft?
    var inboxItemID: UUID?
}

/// Orchestrates one request: chooses the provider or the deterministic path, runs it, composes
/// the response from what actually happened, and never loses the user's input.
@MainActor
@Observable
final class AssistantEngine {
    private(set) var provider: AIProvider?
    let actions: AssistantActions
    private let inbox: InboxService
    private let conversation: ConversationService
    private let settings: SettingsStore
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "Assistant")

    private(set) var isProcessing = false
    private(set) var pendingAction: PendingAction?
    private(set) var lastResult: AssistantResult?
    private(set) var lastAvailability: AIAvailability = .notSupportedByThisBuild
    /// Real reversals available for records shown on screen (record id → operation).
    private(set) var undoRegistry: [UUID: UndoOperation] = [:]

    var now: () -> Date = { Date() }

    init(provider: AIProvider?, actions: AssistantActions, inbox: InboxService, conversation: ConversationService, settings: SettingsStore) {
        self.provider = provider
        self.actions = actions
        self.inbox = inbox
        self.conversation = conversation
        self.settings = settings
        refreshAvailability()
    }

    func refreshAvailability() {
        lastAvailability = provider?.availability() ?? .notSupportedByThisBuild
    }

    var mode: AssistantMode { lastAvailability.isAvailable ? .appleIntelligence : .deterministic }

    private var calendar: Calendar { settings.calendar }
    private var interpreter: RuleBasedInterpreter { RuleBasedInterpreter(calendar: calendar, now: now(), defaults: settings.timeDefaults) }

    // MARK: - Entry points

    func handle(_ rawText: String, source: CaptureSource) async -> AssistantResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AssistantResult(responseText: "I didn't catch anything.", actions: [], mode: mode)
        }
        isProcessing = true
        defer { isProcessing = false }
        refreshAvailability()
        conversation.append(role: .user, text: text)
        actions.log.reset()
        actions.now = now
        actions.currentTranscript = text

        // Yes/no while a confirmation is pending.
        if let pending = pendingAction {
            if Self.isAffirmative(text) { return await confirmPending(pending) }
            if Self.isNegative(text) { return cancelPending() }
        }

        let ruleIntent = interpreter.interpret(text)

        // Bulk deletion never goes through the model: the rule is explicit and must be confirmed.
        if ruleIntent == .deleteAllReminders || ruleIntent == .deleteAllMemories {
            return await runDeterministic(ruleIntent, text: text, source: source, mode: mode)
        }

        if lastAvailability.isAvailable, let provider {
            do {
                let request = makeRequest(text)
                let response = try await provider.process(request, actions: actions)
                if let question = response.clarificationQuestion, actions.log.records.isEmpty {
                    // Prefer a deterministic reading when the rules are confident; otherwise ask.
                    if Self.isConfident(ruleIntent) {
                        return await runDeterministic(ruleIntent, text: text, source: source, mode: .appleIntelligence)
                    }
                    let result = finish(modelText: question, records: [ActionRecord(.needsClarification(question: question))], mode: .appleIntelligence,
                                        suggested: suggestedDrafts(for: ruleIntent), text: text, source: source, inboxReason: nil)
                    return result
                }
                if actions.log.records.isEmpty, Self.isConfident(ruleIntent) {
                    // The model answered in prose without acting; the deterministic parser is sure. Act deterministically.
                    logger.info("Model made no tool call; using deterministic interpretation")
                    return await runDeterministic(ruleIntent, text: text, source: source, mode: .appleIntelligence)
                }
                return finish(modelText: response.text, records: actions.log.records, mode: .appleIntelligence, suggested: nil, text: text, source: source,
                              inboxReason: (actions.log.records.isEmpty && ruleIntent == .unknown && Self.looksLikeCommand(text)) ? .ambiguous : nil)
            } catch let error as AIProcessingError {
                logger.error("Provider failed: \(error.localizedDescription, privacy: .public)")
                if Self.isConfident(ruleIntent) {
                    return await runDeterministic(ruleIntent, text: text, source: source, mode: .deterministic, note: error.localizedDescription)
                }
                return saveToInbox(text: text, source: source, reason: error.inboxReason, detail: error.localizedDescription, mode: .deterministic, ruleIntent: ruleIntent)
            } catch {
                logger.error("Provider threw: \(error.localizedDescription, privacy: .public)")
                if Self.isConfident(ruleIntent) {
                    return await runDeterministic(ruleIntent, text: text, source: source, mode: .deterministic, note: error.localizedDescription)
                }
                return saveToInbox(text: text, source: source, reason: .modelFailed, detail: error.localizedDescription, mode: .deterministic, ruleIntent: ruleIntent)
            }
        }

        return await runDeterministic(ruleIntent, text: text, source: source, mode: .deterministic)
    }

    /// Re-processes an Inbox item (e.g. after Apple Intelligence became available).
    func retry(_ item: InboxItem) async -> AssistantResult {
        var result = await handle(item.text, source: item.source)
        // A failed retry re-files the text; keep the original item instead of a duplicate.
        if let newID = result.inboxItemID, newID != item.id, let duplicate = inbox.fetch(id: newID) {
            inbox.delete(duplicate)
            result.inboxItemID = item.id
        }
        if result.actions.contains(where: { $0.changedData }) || result.pending != nil {
            inbox.markResolved(item)
        } else {
            let reason: InboxReason = lastAvailability.isAvailable ? .ambiguous : .modelUnavailable
            inbox.recordRetry(item, reason: reason, detail: result.responseText)
        }
        return result
    }

    // MARK: - Confirmations and choices

    func confirmPending(_ pending: PendingAction? = nil) async -> AssistantResult {
        guard let action = pending ?? pendingAction else {
            return AssistantResult(responseText: "There's nothing waiting for confirmation.", actions: [], mode: mode)
        }
        pendingAction = nil
        actions.log.reset()
        switch action {
        case .deleteAllReminders:
            do {
                let n = try await actions.reminders.deleteAll()
                actions.focusReminderID = nil
                actions.log.record(.remindersDeleted(count: n))
            } catch {
                actions.log.record(.failed(operation: "delete all reminders", message: error.localizedDescription))
            }
        case .deleteAllMemories:
            do {
                let n = try actions.memories.deleteAll()
                actions.lastSavedMemoryID = nil
                actions.log.record(.memoriesDeleted(count: n))
            } catch {
                actions.log.record(.failed(operation: "delete all memories", message: error.localizedDescription))
            }
        case .createReminderDespiteDuplicate(let draft, let transcript, _):
            actions.currentTranscript = transcript
            _ = await actions.createReminder(draft: draft, allowDuplicate: true)
        case .chooseReminder:
            return AssistantResult(responseText: action.question, actions: [], mode: mode, pending: action)
        }
        return finishSimple(mode: mode)
    }

    func cancelPending() -> AssistantResult {
        pendingAction = nil
        actions.log.reset()
        let result = AssistantResult(responseText: "Okay, cancelled. Nothing was changed.", actions: [], mode: mode)
        conversation.append(role: .assistant, text: result.responseText)
        lastResult = result
        return result
    }

    /// The user picked one of several matching reminders.
    func choose(reminderID: UUID) async -> AssistantResult {
        guard case .chooseReminder(_, let followOn)? = pendingAction else {
            return AssistantResult(responseText: "There's no choice waiting.", actions: [], mode: mode)
        }
        pendingAction = nil
        actions.log.reset()
        let id = reminderID.uuidString
        switch followOn {
        case .complete: _ = await actions.completeReminder(query: nil, id: id)
        case .delete: _ = await actions.deleteReminder(query: nil, id: id, deleteAll: false)
        case .snooze(let interval): _ = await actions.snoozeReminder(query: nil, id: id, minutes: Int(interval / 60))
        case .reschedule(let date): _ = await actions.updateReminder(query: nil, id: id, changes: ReminderChanges(dueDate: .some(date)))
        case .update(let changes): _ = await actions.updateReminder(query: nil, id: id, changes: changes)
        case .followUp(let date): _ = await actions.followUp(query: nil, id: id, at: date)
        case .assignProject(let name): _ = await actions.updateReminder(query: nil, id: id, changes: ReminderChanges(projectName: .some(name)))
        }
        return finishSimple(mode: mode)
    }

    // MARK: - Undo and card controls

    func canUndo(_ record: ActionRecord) -> Bool { undoRegistry[record.id] != nil }

    /// Reverses a previous action. Only offered where a genuine reversal exists.
    func undo(_ record: ActionRecord) async -> AssistantResult {
        guard let operation = undoRegistry[record.id] else {
            return AssistantResult(responseText: "There's nothing to undo for that.", actions: [], mode: mode)
        }
        undoRegistry[record.id] = nil
        actions.log.reset()
        do {
            switch operation {
            case .deleteReminder(let id, _):
                if let r = actions.reminders.fetch(id: id) { try await actions.reminders.delete(r) }
                if actions.focusReminderID == id { actions.focusReminderID = nil }
            case .restoreReminderState(let id, _, let due, let status, let completedAt, let followUp, let dropLastSnooze):
                guard let r = actions.reminders.fetch(id: id) else { throw ReminderServiceError.notFound }
                try await actions.reminders.restore(r, dueDate: due, status: status, completedAt: completedAt, followUpDate: followUp, dropLastSnooze: dropLastSnooze)
                actions.focusReminderID = id
            case .restoreReminder(let snapshot):
                let r = try await actions.reminders.restore(snapshot)
                actions.focusReminderID = r.id
            case .deleteMemory(let id, _):
                if let m = actions.memories.fetch(id: id) { try actions.memories.delete(m) }
                if actions.lastSavedMemoryID == id { actions.lastSavedMemoryID = nil }
            case .restoreMemory(let snapshot):
                let m = try actions.memories.restore(snapshot)
                actions.lastSavedMemoryID = m.id
            }
            actions.log.record(.undone(operation.description))
        } catch {
            actions.log.record(.failed(operation: "undo that", message: error.localizedDescription))
        }
        return finishSimple(mode: mode)
    }

    /// Builds a result from whatever `actions.log` currently holds (used by flows that call
    /// `AssistantActions` directly, such as the photo sheet).
    func resultFromCurrentLog() -> AssistantResult { finishSimple(mode: mode) }

    /// "Done" on a confirmation card.
    func complete(reminderID: UUID) async -> AssistantResult {
        actions.log.reset()
        _ = await actions.completeReminder(query: nil, id: reminderID.uuidString)
        return finishSimple(mode: mode)
    }

    // MARK: - Deterministic path

    private func runDeterministic(_ intent: InterpretedIntent, text: String, source: CaptureSource, mode: AssistantMode, note: String? = nil) async -> AssistantResult {
        actions.log.reset()
        switch intent {
        case .createReminder(let draft):
            if draft.clarificationQuestion != nil, draft.dueDate == nil {
                actions.log.record(.needsClarification(question: draft.clarificationQuestion ?? "When should I remind you?"))
                return finish(modelText: nil, records: actions.log.records, mode: mode, suggested: (draft, nil), text: text, source: source, inboxReason: nil)
            }
            _ = await actions.createReminder(draft: draft)
        case .saveMemory(let draft):
            _ = actions.saveMemory(draft: draft)
        case .createReminderAndMemory(let r, let m):
            _ = actions.saveMemory(draft: m)
            _ = await actions.createReminder(draft: r)
        case .searchMemories(let q):
            _ = actions.searchMemories(query: q, personName: nil, projectName: nil)
        case .listReminders(let scope):
            _ = actions.listReminders(scope: scope)
        case .completeReminder(let ref):
            _ = await actions.completeReminder(query: ref.titleHint, id: nil, reference: ref)
        case .snoozeReminder(let ref, let duration):
            _ = await actions.snoozeReminder(query: ref.titleHint, id: nil, reference: ref, minutes: Int(duration / 60))
        case .rescheduleReminder(let ref, let date, let hasTime):
            var target = date
            if !hasTime, case .one(let r) = actions.resolveReminder(query: ref.titleHint, id: nil, reference: ref), let due = r.dueDate {
                target = calendar.date(bySettingHour: calendar.component(.hour, from: due), minute: calendar.component(.minute, from: due), second: 0, of: date) ?? date
            }
            _ = await actions.updateReminder(query: ref.titleHint, id: nil, reference: ref, changes: ReminderChanges(dueDate: .some(target)))
        case .deleteReminder(let ref):
            _ = await actions.deleteReminder(query: ref.titleHint, id: nil, reference: ref, deleteAll: false)
        case .followUpReminder(let ref, let date):
            _ = await actions.followUp(query: ref.titleHint, id: nil, reference: ref, at: date)
        case .deleteAllReminders:
            _ = await actions.deleteReminder(query: nil, id: nil, deleteAll: true)
        case .deleteAllMemories:
            _ = actions.deleteMemory(query: nil, id: nil, deleteAll: true)
        case .assignToProject(let name):
            _ = await actions.associateItemWithProject(projectName: name, itemKind: "lastSaved", itemQuery: nil)
        case .dailyBriefing:
            _ = actions.dailyBriefing()
        case .unknown:
            let reason: InboxReason = mode == .deterministic ? (lastAvailability.isAvailable ? .modelFailed : .modelUnavailable) : .ambiguous
            return saveToInbox(text: text, source: source, reason: reason, detail: note, mode: mode, ruleIntent: intent)
        }
        if let note, mode == .deterministic, lastAvailability.isAvailable {
            // The model failed but the rules were confident; the card shows exactly what happened.
            logger.info("Used built-in rules after model failure: \(note, privacy: .public)")
        }
        return finish(modelText: nil, records: actions.log.records, mode: mode, suggested: nil, text: text, source: source, inboxReason: nil)
    }

    private func saveToInbox(text: String, source: CaptureSource, reason: InboxReason, detail: String?, mode: AssistantMode, ruleIntent: InterpretedIntent) -> AssistantResult {
        let item = inbox.add(text: text, source: source, reason: reason, detail: detail)
        var records = actions.log.records
        records.append(ActionRecord(.savedToInbox(reason: reason)))
        var result = finish(modelText: nil, records: records, mode: mode, suggested: suggestedDrafts(for: ruleIntent), text: text, source: source, inboxReason: nil)
        result.inboxItemID = item?.id
        if !lastAvailability.isAvailable, case .unavailable(let why, let suggestion, _) = lastAvailability {
            result.responseText = "\(why) \(suggestion ?? "") I kept what you said in the Inbox, and you can turn it into a reminder or note with the form."
        }
        return result
    }

    // MARK: - Finishing

    private func finish(modelText: String?, records: [ActionRecord], mode: AssistantMode, suggested: (ReminderDraft?, MemoryDraft?)?,
                        text: String, source: CaptureSource, inboxReason: InboxReason?) -> AssistantResult {
        var records = records
        var inboxID: UUID?
        if let inboxReason {
            let item = inbox.add(text: text, source: source, reason: inboxReason, detail: modelText)
            inboxID = item?.id
            records.append(ActionRecord(.savedToInbox(reason: inboxReason)))
        } else if records.contains(where: { if case .failed = $0.kind { return true }; return false }) {
            let item = inbox.add(text: text, source: source, reason: .toolFailed, detail: records.compactMap { if case .failed(_, let m) = $0.kind { return m }; return nil }.first)
            inboxID = item?.id
        }
        pendingAction = actions.log.pending
        undoRegistry.merge(actions.log.undoOperations) { _, new in new }
        let composer = ResponseComposer(now: now(), calendar: calendar)
        let response = composer.compose(records: records, modelText: modelText, pending: pendingAction)
        let result = AssistantResult(responseText: response, actions: records, mode: mode, pending: pendingAction,
                                     suggestedReminder: suggested?.0, suggestedMemory: suggested?.1, inboxItemID: inboxID)
        conversation.append(role: .assistant, text: response, actionSummary: records.first.map { Self.summary($0) })
        lastResult = result
        return result
    }

    private func finishSimple(mode: AssistantMode) -> AssistantResult {
        pendingAction = actions.log.pending
        undoRegistry.merge(actions.log.undoOperations) { _, new in new }
        let composer = ResponseComposer(now: now(), calendar: calendar)
        let response = composer.compose(records: actions.log.records, modelText: nil, pending: pendingAction)
        let result = AssistantResult(responseText: response, actions: actions.log.records, mode: mode, pending: pendingAction)
        conversation.append(role: .assistant, text: response, actionSummary: actions.log.records.first.map { Self.summary($0) })
        lastResult = result
        return result
    }

    private func makeRequest(_ text: String) -> AssistantRequest {
        let focus = actions.focusReminderID.flatMap { actions.reminders.fetch(id: $0) }.map { actions.reminders.summary($0) }
        let memory = actions.lastSavedMemoryID.flatMap { actions.memories.fetch(id: $0) }.map { MemorySummary($0) }
        let turns = conversation.recent(limit: 7).dropLast().map { TurnSnapshot(role: $0.role, text: $0.text) }
        return AssistantRequest(text: text, now: now(), calendar: calendar, timeDefaults: settings.timeDefaults, focusReminder: focus,
                                lastSavedMemory: memory, recentTurns: Array(turns))
    }

    private func suggestedDrafts(for intent: InterpretedIntent) -> (ReminderDraft?, MemoryDraft?)? {
        switch intent {
        case .createReminder(let d): return (d, nil)
        case .saveMemory(let m): return (nil, m)
        case .createReminderAndMemory(let d, let m): return (d, m)
        default: return nil
        }
    }

    static func isConfident(_ intent: InterpretedIntent) -> Bool {
        switch intent {
        case .unknown: return false
        case .createReminder(let d): return d.dueDate != nil || d.recurrence != nil
        default: return true
        }
    }

    static func looksLikeCommand(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(remind|remember|save|note|schedule|move|snooze|delete|complete|list|show)\b"#, options: .regularExpression) != nil
    }

    static func isAffirmative(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["yes", "yes please", "yeah", "yep", "sure", "do it", "confirm", "go ahead", "ok", "okay", "correct", "delete them", "yes delete them", "yes delete all"].contains(t)
    }

    static func isNegative(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["no", "nope", "cancel", "stop", "never mind", "nevermind", "don't", "do not", "no thanks"].contains(t)
    }

    static func summary(_ record: ActionRecord) -> String {
        switch record.kind {
        case .reminderCreated(let r): return "Created reminder “\(r.title)”"
        case .reminderUpdated(let r, _): return "Updated reminder “\(r.title)”"
        case .reminderCompleted(let r, _): return "Completed “\(r.title)”"
        case .reminderDeleted(let t): return "Deleted “\(t)”"
        case .reminderSnoozed(let r, _): return "Snoozed “\(r.title)”"
        case .reminderFollowUpSet(let r, _): return "Follow-up for “\(r.title)”"
        case .remindersDeleted(let n): return "Deleted \(n) reminders"
        case .remindersListed(let l, _): return "Listed \(l.count) reminders"
        case .memorySaved(let m): return "Saved memory “\(m.title)”"
        case .memoryUpdated(let m, _): return "Updated memory “\(m.title)”"
        case .memoryDeleted(let t): return "Deleted memory “\(t)”"
        case .memoriesDeleted(let n): return "Deleted \(n) memories"
        case .memoriesFound(let l, _): return "Found \(l.count) memories"
        case .projectCreated(let n): return "Project “\(n)”"
        case .itemAssignedToProject(let i, let p): return "Filed “\(i)” under \(p)"
        case .briefing: return "Briefing"
        case .needsConfirmation: return "Awaiting confirmation"
        case .needsChoice: return "Awaiting choice"
        case .needsClarification: return "Asked a question"
        case .notFound: return "Not found"
        case .failed(let op, _): return "Failed to \(op)"
        case .savedToInbox: return "Saved to Inbox"
        case .undone(let d): return "Undone: \(d)"
        }
    }
}
