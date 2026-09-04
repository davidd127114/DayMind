import Foundation
import DayMindCore

/// Turns action records into the exact confirmation the user hears. Deterministic: the on-device
/// model's own wording is used only when no data changed (answers, small talk).
struct ResponseComposer {
    var now: Date
    var calendar: Calendar

    func compose(records: [ActionRecord], modelText: String?, pending: PendingAction?) -> String {
        var sentences: [String] = []
        for record in records {
            if let s = sentence(for: record) { sentences.append(s) }
        }
        if let pending, !records.contains(where: { if case .needsConfirmation = $0.kind { return true }; if case .needsChoice = $0.kind { return true }; return false }) {
            sentences.append(pending.question)
        }
        if sentences.isEmpty {
            if let modelText, !modelText.isEmpty { return modelText }
            return "I'm not sure what to do with that. You can rephrase it, or turn it into a reminder or note from the Inbox."
        }
        return sentences.joined(separator: " ")
    }

    func sentence(for record: ActionRecord) -> String? {
        switch record.kind {
        case .reminderCreated(let r):
            var text = SpokenFormatter.reminderConfirmation(title: r.title, date: r.dueDate, recurrence: nil, now: now, calendar: calendar)
            if let rec = r.recurrenceText, let due = r.dueDate {
                text = "Done. I'll remind you to \(SpokenFormatter.lowercaseFirst(r.title)) \(rec), starting \(SpokenFormatter.dateTimePhrase(due, now: now, calendar: calendar))."
            }
            if let project = r.projectName { text += " Filed under \(project)." }
            return text
        case .reminderUpdated(let r, let change):
            if let due = r.dueDate, change.hasPrefix("moved") {
                return "Done. “\(r.title)” is now \(SpokenFormatter.dateTimePhrase(due, now: now, calendar: calendar))."
            }
            return "Done. “\(r.title)” was \(change)."
        case .reminderCompleted(let r, let next):
            if let next { return "Marked “\(r.title)” done. The next one is \(SpokenFormatter.dateTimePhrase(next, now: now, calendar: calendar))." }
            return "Marked “\(r.title)” as done."
        case .reminderDeleted(let title):
            return "Deleted “\(title)”."
        case .reminderSnoozed(let r, let until):
            return "Snoozed “\(r.title)” until \(SpokenFormatter.dateTimePhrase(until, now: now, calendar: calendar))."
        case .reminderFollowUpSet(let r, let at):
            return "Okay. If “\(r.title)” isn't done, I'll remind you again \(SpokenFormatter.dateTimePhrase(at, now: now, calendar: calendar))."
        case .remindersDeleted(let count):
            return count == 0 ? "There were no reminders to delete." : "Deleted \(count) reminder\(count == 1 ? "" : "s")."
        case .remindersListed(let list, let scope):
            return listSentence(list, scope: scope)
        case .memorySaved(let m):
            var text = "Got it. I'll remember that \(SpokenFormatter.lowercaseFirst(m.content.trimmingCharacters(in: CharacterSet(charactersIn: "."))))."
            if let project = m.projectName { text += " Filed under \(project)." }
            return text
        case .memoryUpdated(let m, let change):
            return "Memory “\(m.title)” \(change)."
        case .memoryDeleted(let title):
            return "Deleted the memory “\(title)”."
        case .memoriesDeleted(let count):
            return count == 0 ? "There were no memories to delete." : "Deleted \(count) memor\(count == 1 ? "y" : "ies")."
        case .memoriesFound(let list, let query):
            if list.isEmpty { return "I don't have anything saved about \(query)." }
            let items = list.prefix(4).map { $0.content.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            let prefix = list.count == 1 ? "Here's what you told me about \(query): " : "Here's what you told me about \(query): "
            return prefix + items.joined(separator: ". ") + "."
        case .projectCreated(let name):
            return "Project “\(name)” is ready."
        case .itemAssignedToProject(let item, let project):
            return "Filed “\(item)” under \(project)."
        case .briefing(let text):
            return text
        case .needsConfirmation(let p), .needsChoice(let p):
            return p.question
        case .needsClarification(let q):
            return q
        case .notFound(let what):
            return "I couldn't find \(what), so nothing was changed."
        case .failed(let op, let message):
            return "I could not \(op): \(message) Nothing was saved. I kept your request in the Inbox."
        case .savedToInbox(let reason):
            return "I saved what you said to the Inbox because \(reason.displayName.lowercased()). You can turn it into a reminder or note from there."
        }
    }

    func listSentence(_ list: [ReminderSummary], scope: ReminderListScope) -> String {
        let scopeName: String
        switch scope {
        case .today: scopeName = "today"
        case .overdue: scopeName = "overdue"
        case .upcoming: scopeName = "coming up"
        case .tomorrow: scopeName = "tomorrow"
        case .thisWeek: scopeName = "this week"
        case .forgottenYesterday: scopeName = "yesterday"
        case .all: scopeName = "in total"
        }
        if list.isEmpty {
            switch scope {
            case .forgottenYesterday: return "You didn't miss anything yesterday."
            case .overdue: return "Nothing is overdue."
            case .today: return "Nothing is due today. You're all caught up."
            default: return "Nothing is scheduled \(scopeName)."
            }
        }
        let overdue = list.filter { $0.dueDate.map { $0 < now } ?? false }
        let described = list.prefix(5).map { r -> String in
            guard let due = r.dueDate else { return r.title }
            if scope == .today || scope == .tomorrow { return "\(r.title) at \(SpokenFormatter.timeString(due, calendar: calendar))" }
            return "\(r.title) \(SpokenFormatter.dateTimePhrase(due, now: now, calendar: calendar))"
        }
        var text: String
        switch scope {
        case .forgottenYesterday:
            text = "Yesterday you missed \(list.count == 1 ? "one thing" : "\(list.count) things"): \(RecurrenceRule.joinList(Array(described)))."
        default:
            text = "You have \(list.count) reminder\(list.count == 1 ? "" : "s") \(scopeName): \(RecurrenceRule.joinList(Array(described)))."
        }
        if list.count > 5 { text += " Plus \(list.count - 5) more." }
        if scope == .today, !overdue.isEmpty { text += " \(overdue.count) of them \(overdue.count == 1 ? "is" : "are") overdue." }
        return text
    }
}
