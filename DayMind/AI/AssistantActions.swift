import Foundation
import DayMindCore

/// The single place where an interpreted request (from the on-device model *or* the deterministic
/// parser) becomes a validated database change. Every method validates its arguments, performs
/// the change through the services, records an `ActionRecord`, and returns a short plain-text
/// result for the model. Nothing here trusts the model's wording.
@MainActor
final class AssistantActions: @unchecked Sendable {
    let reminders: ReminderService
    let memories: MemoryService
    let projects: ProjectService
    let people: PersonService
    let briefing: BriefingService
    let settings: SettingsStore
    let log = ActionLog()

    /// The reminder "that"/"it" refers to, and the most recently saved memory.
    var focusReminderID: UUID?
    var lastSavedMemoryID: UUID?
    var currentTranscript: String?
    var now: () -> Date = { Date() }

    init(reminders: ReminderService, memories: MemoryService, projects: ProjectService, people: PersonService, briefing: BriefingService, settings: SettingsStore) {
        self.reminders = reminders
        self.memories = memories
        self.projects = projects
        self.people = people
        self.briefing = briefing
        self.settings = settings
    }

    private var calendar: Calendar { settings.calendar }
    private var dateParser: NaturalDateParser { NaturalDateParser(calendar: calendar, now: now(), defaults: settings.timeDefaults) }
    private var recurrenceParser: RecurrenceParser { RecurrenceParser(calendar: calendar, defaults: settings.timeDefaults) }

    // MARK: - Reminders

    func createReminder(title: String, dateExpression: String?, timeExpression: String?, recurrenceExpression: String?, notes: String?,
                        people: [String], projectName: String?, priority: String?, allowDuplicate: Bool = false) async -> String {
        var draft = ReminderDraft(title: title, notes: notes ?? "", people: people.filter { !$0.isEmpty }, projectName: nonEmpty(projectName))
        draft.priority = ReminderPriority(rawValue: (priority ?? "normal").lowercased()) ?? .normal

        if let recurrenceText = nonEmpty(recurrenceExpression) {
            guard let parsed = recurrenceParser.parse(recurrenceText) ?? recurrenceParser.parse("every " + recurrenceText) else {
                log.record(.needsClarification(question: "How often should “\(title)” repeat? For example “every Monday” or “every first Monday of the month”."))
                return "Could not understand the repeat pattern '\(recurrenceText)'. Ask the user how often it should repeat."
            }
            draft.recurrence = parsed.rule
            let time: TimeOfDay
            if let t = nonEmpty(timeExpression), let parsedTime = dateParser.parse(t), parsedTime.hasExplicitTime {
                time = TimeOfDay(hour: calendar.component(.hour, from: parsedTime.date), minute: calendar.component(.minute, from: parsedTime.date))
            } else if let implied = parsed.impliedTime {
                time = implied
            } else {
                time = settings.timeDefaults.morning
            }
            let anchorDay: Date
            if let d = nonEmpty(dateExpression), let parsedDate = dateParser.resolve(dateExpression: d, timeExpression: nil) {
                anchorDay = calendar.startOfDay(for: parsedDate.date)
            } else {
                anchorDay = calendar.startOfDay(for: now())
            }
            let anchor = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: anchorDay) ?? anchorDay
            draft.dueDate = parsed.rule.nextOccurrence(after: now().addingTimeInterval(-1), anchor: anchor, calendar: calendar) ?? anchor
            draft.hasExplicitTime = true
        } else if nonEmpty(dateExpression) != nil || nonEmpty(timeExpression) != nil {
            guard let resolved = dateParser.resolve(dateExpression: nonEmpty(dateExpression), timeExpression: nonEmpty(timeExpression)) else {
                let said = [dateExpression, timeExpression].compactMap { nonEmpty($0) }.joined(separator: " ")
                log.record(.needsClarification(question: "When exactly should I remind you? I didn't understand “\(said)”."))
                return "Could not understand the date/time '\(said)'. Ask the user for an exact day and time."
            }
            draft.dueDate = resolved.date
            draft.hasExplicitTime = resolved.hasExplicitTime
        }

        return await createReminder(draft: draft, allowDuplicate: allowDuplicate)
    }

    func createReminder(draft: ReminderDraft, allowDuplicate: Bool = false) async -> String {
        if let question = draft.clarificationQuestion, draft.dueDate == nil {
            log.record(.needsClarification(question: question))
            return "The reminder has no date yet. Ask: \(question)"
        }
        do {
            let reminder = try await reminders.create(from: draft, transcript: currentTranscript, allowDuplicate: allowDuplicate)
            focusReminderID = reminder.id
            let summary = reminders.summary(reminder)
            log.record(.reminderCreated(summary), undo: .deleteReminder(id: reminder.id, title: reminder.title))
            return "Saved reminder '\(summary.title)'" + (summary.dueDate.map { " for \(phrase($0))" } ?? " with no date") + (summary.recurrenceText.map { ", repeating \($0)" } ?? "") + "."
        } catch ReminderServiceError.possibleDuplicate(let existingID, _) {
            if let existing = reminders.fetch(id: existingID) {
                log.record(.needsConfirmation(.createReminderDespiteDuplicate(draft, transcript: currentTranscript, existing: reminders.summary(existing))))
                return "A similar reminder already exists ('\(existing.title)'). The user is being asked whether to add it anyway; do not create it again."
            }
            log.record(.failed(operation: "create reminder", message: "Duplicate check failed."))
            return "Failed."
        } catch {
            log.record(.failed(operation: "create reminder", message: error.localizedDescription))
            return "Failed to save the reminder: \(error.localizedDescription). Tell the user it was NOT saved."
        }
    }

    enum Resolution { case one(Reminder), none, many([Reminder]) }

    func resolveReminder(query: String?, id: String?, reference: ReminderReference? = nil) -> Resolution {
        if let id, let uuid = UUID(uuidString: id), let r = reminders.fetch(id: uuid) { return .one(r) }
        var ref = reference ?? ReminderReference(titleHint: nonEmpty(query))
        if ref.titleHint == nil && ref.dayHint == nil { ref.usesAnaphora = true }
        if let q = nonEmpty(query), reference == nil {
            let lowered = q.lowercased()
            if ["that", "it", "this", "that one", "the last one", "this one"].contains(lowered) { ref = ReminderReference(usesAnaphora: true) }
        }
        let matches = reminders.find(reference: ref, focusID: focusReminderID)
        switch matches.count {
        case 0: return .none
        case 1: return .one(matches[0])
        default: return .many(matches)
        }
    }

    func updateReminder(query: String?, id: String?, reference: ReminderReference? = nil, changes: ReminderChanges) async -> String {
        switch resolveReminder(query: query, id: id, reference: reference) {
        case .none:
            log.record(.notFound(what: "a reminder matching “\(query ?? "that")”"))
            return "No matching reminder found. Tell the user nothing was changed."
        case .many(let list):
            log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .update(changes))))
            return "Several reminders match (\(list.map(\.title).joined(separator: "; "))). The user is being asked to choose; do not change anything yet."
        case .one(let r):
            return await performUpdate(changes, on: r)
        }
    }

    func updateReminder(query: String?, id: String?, newTitle: String?, newDateExpression: String?, newTimeExpression: String?, newNotes: String?, newPriority: String?) async -> String {
        var changes = ReminderChanges()
        if let t = nonEmpty(newTitle) { changes.title = t }
        if let n = newNotes, !n.isEmpty { changes.notes = n }
        if let p = nonEmpty(newPriority) { changes.priority = ReminderPriority(rawValue: p.lowercased()) }
        if nonEmpty(newDateExpression) != nil || nonEmpty(newTimeExpression) != nil {
            // Keep the existing time when only a day was given.
            var base: Date? = nil
            if case .one(let r) = resolveReminder(query: query, id: id), let due = r.dueDate { base = due }
            guard var resolved = dateParser.resolve(dateExpression: nonEmpty(newDateExpression), timeExpression: nonEmpty(newTimeExpression)) else {
                log.record(.needsClarification(question: "When should I move it to? Please give a day and time."))
                return "Could not understand the new date/time. Ask the user for an exact day and time."
            }
            if !resolved.hasExplicitTime, let base {
                let h = calendar.component(.hour, from: base), m = calendar.component(.minute, from: base)
                resolved.date = calendar.date(bySettingHour: h, minute: m, second: 0, of: resolved.date) ?? resolved.date
            }
            changes.dueDate = .some(resolved.date)
        }
        guard changes != ReminderChanges() else {
            log.record(.needsClarification(question: "What would you like to change about that reminder?"))
            return "No change was specified. Ask the user what to change."
        }
        return await updateReminder(query: query, id: id, changes: changes)
    }

    private func performUpdate(_ changes: ReminderChanges, on r: Reminder) async -> String {
        do {
            let before = reminders.summary(r)
            let priorDue = r.dueDate, priorStatus = r.status, priorCompleted = r.completedAt, priorFollowUp = r.followUpDate
            try await reminders.apply(changes, to: r)
            focusReminderID = r.id
            let after = reminders.summary(r)
            var describe: [String] = []
            if let t = changes.title { describe.append("renamed to “\(t)”") }
            if case .some(let d) = changes.dueDate { describe.append(d.map { "moved to \(phrase($0))" } ?? "date removed") }
            if changes.priority != nil { describe.append("priority \(after.priority.displayName.lowercased())") }
            if changes.notes != nil { describe.append("notes updated") }
            if case .some(let p) = changes.projectName { describe.append(p.map { "filed under \($0)" } ?? "removed from project") }
            let change = describe.isEmpty ? "updated" : describe.joined(separator: ", ")
            let undo: UndoOperation? = changes.dueDate != nil
                ? .restoreReminderState(id: r.id, title: after.title, dueDate: priorDue, status: priorStatus, completedAt: priorCompleted, followUpDate: priorFollowUp, dropLastSnooze: false)
                : nil
            log.record(.reminderUpdated(after, change: change), undo: undo)
            return "Updated '\(before.title)': \(change)."
        } catch {
            log.record(.failed(operation: "update reminder", message: error.localizedDescription))
            return "Failed to update: \(error.localizedDescription). Tell the user nothing changed."
        }
    }

    func completeReminder(query: String?, id: String?, reference: ReminderReference? = nil) async -> String {
        switch resolveReminder(query: query, id: id, reference: reference) {
        case .none:
            log.record(.notFound(what: "a reminder matching “\(query ?? "that")”"))
            return "No matching reminder found."
        case .many(let list):
            log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .complete)))
            return "Several reminders match. The user is being asked to choose."
        case .one(let r):
            do {
                let priorDue = r.dueDate, priorStatus = r.status, priorCompleted = r.completedAt, priorFollowUp = r.followUpDate
                let next = try await reminders.complete(r)
                focusReminderID = r.id
                log.record(.reminderCompleted(reminders.summary(r), nextOccurrence: next),
                           undo: .restoreReminderState(id: r.id, title: r.title, dueDate: priorDue, status: priorStatus, completedAt: priorCompleted, followUpDate: priorFollowUp, dropLastSnooze: false))
                return "Completed '\(r.title)'" + (next.map { ". Next occurrence \(phrase($0))" } ?? "") + "."
            } catch {
                log.record(.failed(operation: "complete reminder", message: error.localizedDescription))
                return "Failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteReminder(query: String?, id: String?, reference: ReminderReference? = nil, deleteAll: Bool) async -> String {
        if deleteAll {
            let count = reminders.fetchAll().count
            log.record(.needsConfirmation(.deleteAllReminders(count: count)))
            return "Deleting all \(count) reminders requires the user's explicit confirmation, which is being requested now. Do not say they were deleted."
        }
        switch resolveReminder(query: query, id: id, reference: reference) {
        case .none:
            log.record(.notFound(what: "a reminder matching “\(query ?? "that")”"))
            return "No matching reminder found."
        case .many(let list):
            log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .delete)))
            return "Several reminders match. The user is being asked to choose."
        case .one(let r):
            let title = r.title
            let snapshot = reminders.snapshot(r)
            do {
                try await reminders.delete(r)
                if focusReminderID == r.id { focusReminderID = nil }
                log.record(.reminderDeleted(title: title), undo: .restoreReminder(snapshot))
                return "Deleted '\(title)'."
            } catch {
                log.record(.failed(operation: "delete reminder", message: error.localizedDescription))
                return "Failed: \(error.localizedDescription)"
            }
        }
    }

    func snoozeReminder(query: String?, id: String?, reference: ReminderReference? = nil, minutes: Int) async -> String {
        let clamped = min(max(minutes, 1), 60 * 24 * 30)
        switch resolveReminder(query: query, id: id, reference: reference) {
        case .none:
            log.record(.notFound(what: "a reminder to snooze"))
            return "No matching reminder found."
        case .many(let list):
            log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .snooze(Double(clamped) * 60))))
            return "Several reminders match. The user is being asked to choose."
        case .one(let r):
            do {
                let priorDue = r.dueDate, priorStatus = r.status, priorCompleted = r.completedAt, priorFollowUp = r.followUpDate
                let until = try await reminders.snooze(r, by: Double(clamped) * 60)
                focusReminderID = r.id
                log.record(.reminderSnoozed(reminders.summary(r), until: until),
                           undo: .restoreReminderState(id: r.id, title: r.title, dueDate: priorDue, status: priorStatus, completedAt: priorCompleted, followUpDate: priorFollowUp, dropLastSnooze: true))
                return "Snoozed '\(r.title)' until \(phrase(until))."
            } catch {
                log.record(.failed(operation: "snooze reminder", message: error.localizedDescription))
                return "Failed: \(error.localizedDescription)"
            }
        }
    }

    func followUp(query: String?, id: String?, reference: ReminderReference? = nil, at date: Date) async -> String {
        switch resolveReminder(query: query, id: id, reference: reference) {
        case .none:
            log.record(.notFound(what: "a reminder to follow up on"))
            return "No matching reminder found."
        case .many(let list):
            log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .followUp(date))))
            return "Several reminders match. The user is being asked to choose."
        case .one(let r):
            do {
                try await reminders.setFollowUp(r, at: date)
                focusReminderID = r.id
                log.record(.reminderFollowUpSet(reminders.summary(r), at: date))
                return "Will remind again \(phrase(date)) if '\(r.title)' is still not completed."
            } catch {
                log.record(.failed(operation: "set follow-up", message: error.localizedDescription))
                return "Failed: \(error.localizedDescription)"
            }
        }
    }

    func listReminders(scope: ReminderListScope) -> String {
        let list = reminders.list(scope: scope)
        let summaries = list.map { reminders.summary($0) }
        if summaries.count == 1 { focusReminderID = summaries[0].id }
        log.record(.remindersListed(summaries, scope: scope))
        if summaries.isEmpty { return "No reminders for scope \(scope.rawValue)." }
        return "Reminders (\(scope.rawValue)): " + summaries.map { "'\($0.title)'" + ($0.dueDate.map { " \(phrase($0))" } ?? "") }.joined(separator: "; ")
    }

    // MARK: - Memories

    func saveMemory(title: String?, content: String, category: String?, people: [String], projectName: String?, tags: [String], importance: String?) -> String {
        let draft = MemoryDraft(title: nonEmpty(title) ?? RuleBasedInterpreter.summaryTitle(content), content: content,
                                category: MemoryCategory(rawValue: (category ?? "").lowercased()) ?? RuleBasedInterpreter.classifyMemory(content.lowercased()),
                                people: people.filter { !$0.isEmpty }, projectName: nonEmpty(projectName), tags: tags,
                                importance: Importance(rawValue: (importance ?? "normal").lowercased()) ?? .normal)
        return saveMemory(draft: draft)
    }

    func saveMemory(draft: MemoryDraft) -> String {
        do {
            let memory = try memories.create(from: draft, transcript: currentTranscript)
            lastSavedMemoryID = memory.id
            log.record(.memorySaved(MemorySummary(memory)), undo: .deleteMemory(id: memory.id, title: memory.title))
            return "Saved memory '\(memory.title)'" + (memory.project.map { " under project \($0.name)" } ?? "") + "."
        } catch {
            log.record(.failed(operation: "save memory", message: error.localizedDescription))
            return "Failed to save the memory: \(error.localizedDescription). Tell the user it was NOT saved."
        }
    }

    private func resolveMemory(query: String?, id: String?) -> Memory? {
        if let id, let uuid = UUID(uuidString: id), let m = memories.fetch(id: uuid) { return m }
        if let q = nonEmpty(query), !["that", "it", "this", "the last one"].contains(q.lowercased()) {
            return memories.search(q, limit: 1).first
        }
        if let lastSavedMemoryID { return memories.fetch(id: lastSavedMemoryID) }
        return memories.mostRecent()
    }

    func updateMemory(query: String?, id: String?, newTitle: String?, newContent: String?, newCategory: String?, archive: Bool?) -> String {
        guard let memory = resolveMemory(query: query, id: id) else {
            log.record(.notFound(what: "a memory matching “\(query ?? "that")”"))
            return "No matching memory found."
        }
        var changes = MemoryChanges()
        if let t = nonEmpty(newTitle) { changes.title = t }
        if let c = nonEmpty(newContent) { changes.content = c }
        if let cat = nonEmpty(newCategory) { changes.category = MemoryCategory(rawValue: cat.lowercased()) }
        if let archive { changes.isArchived = archive }
        do {
            try memories.apply(changes, to: memory)
            lastSavedMemoryID = memory.id
            let change = archive == true ? "archived" : "updated"
            log.record(.memoryUpdated(MemorySummary(memory), change: change))
            return "Memory '\(memory.title)' \(change)."
        } catch {
            log.record(.failed(operation: "update memory", message: error.localizedDescription))
            return "Failed: \(error.localizedDescription)"
        }
    }

    func deleteMemory(query: String?, id: String?, deleteAll: Bool) -> String {
        if deleteAll {
            let count = memories.fetchAll(includeArchived: true).count
            log.record(.needsConfirmation(.deleteAllMemories(count: count)))
            return "Deleting all \(count) memories requires explicit confirmation, which is being requested. Do not say they were deleted."
        }
        guard let memory = resolveMemory(query: query, id: id) else {
            log.record(.notFound(what: "a memory matching “\(query ?? "that")”"))
            return "No matching memory found."
        }
        let title = memory.title
        let snapshot = memories.snapshot(memory)
        do {
            try memories.delete(memory)
            if lastSavedMemoryID == memory.id { lastSavedMemoryID = nil }
            log.record(.memoryDeleted(title: title), undo: .restoreMemory(snapshot))
            return "Deleted memory '\(title)'."
        } catch {
            log.record(.failed(operation: "delete memory", message: error.localizedDescription))
            return "Failed: \(error.localizedDescription)"
        }
    }

    func searchMemories(query: String, personName: String?, projectName: String?, limit: Int = 8) -> String {
        let results = memories.search(query, personName: nonEmpty(personName), projectName: nonEmpty(projectName), limit: max(1, min(limit, 20)))
        let summaries = results.map { MemorySummary($0) }
        log.record(.memoriesFound(summaries, query: query))
        if summaries.isEmpty { return "No memories found for '\(query)'. Tell the user you have nothing saved about that." }
        return "Memories about '\(query)': " + summaries.map { "• \($0.content)" }.joined(separator: " ")
    }

    // MARK: - Projects

    func createProject(name: String, summary: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.record(.needsClarification(question: "What should the project be called?"))
            return "No project name given."
        }
        if let existing = projects.find(name: trimmed) {
            log.record(.projectCreated(name: existing.name))
            return "Project '\(existing.name)' already exists."
        }
        let project = projects.create(name: trimmed, summary: summary ?? "")
        log.record(.projectCreated(name: project.name))
        return "Created project '\(project.name)'."
    }

    /// `itemKind`: "reminder", "memory" or "lastSaved" (the most recent thing the user saved).
    func associateItemWithProject(projectName: String, itemKind: String, itemQuery: String?) async -> String {
        let project = projects.findOrCreate(name: projectName)
        let kind = itemKind.lowercased()
        if kind == "reminder" || (kind == "lastsaved" && lastSavedIsReminder) {
            switch resolveReminder(query: itemQuery, id: nil) {
            case .one(let r):
                do {
                    try await reminders.apply(ReminderChanges(projectName: .some(project.name)), to: r)
                    log.record(.itemAssignedToProject(itemTitle: r.title, project: project.name))
                    return "Filed reminder '\(r.title)' under '\(project.name)'."
                } catch {
                    log.record(.failed(operation: "assign to project", message: error.localizedDescription))
                    return "Failed: \(error.localizedDescription)"
                }
            case .many(let list):
                log.record(.needsChoice(.chooseReminder(candidates: list.map { reminders.summary($0) }, then: .assignProject(project.name))))
                return "Several reminders match. The user is being asked to choose."
            case .none:
                break
            }
        }
        if let memory = resolveMemory(query: itemQuery, id: nil) {
            do {
                try memories.apply(MemoryChanges(projectName: .some(project.name)), to: memory)
                lastSavedMemoryID = memory.id
                log.record(.itemAssignedToProject(itemTitle: memory.title, project: project.name))
                return "Filed memory '\(memory.title)' under '\(project.name)'."
            } catch {
                log.record(.failed(operation: "assign to project", message: error.localizedDescription))
                return "Failed: \(error.localizedDescription)"
            }
        }
        log.record(.notFound(what: "something to file under \(project.name)"))
        return "Nothing found to file under '\(project.name)'. Ask the user what to save there."
    }

    private var lastSavedIsReminder: Bool {
        guard let rid = focusReminderID, let r = reminders.fetch(id: rid) else { return false }
        guard let mid = lastSavedMemoryID, let m = memories.fetch(id: mid) else { return true }
        return r.lastModified > m.lastModified
    }

    // MARK: - Briefing

    func dailyBriefing() -> String {
        let text = briefing.composeText()
        log.record(.briefing(text))
        return text
    }

    // MARK: - Helpers

    func phrase(_ date: Date) -> String {
        SpokenFormatter.dateTimePhrase(date, now: now(), calendar: calendar)
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "none" || t.lowercased() == "null" || t.lowercased() == "n/a" { return nil }
        return t
    }
}
