import Foundation
import DayMindCore

/// Turns action records into the exact confirmation the user hears. Deterministic: the on-device
/// model's own wording is used only when no data changed (answers, small talk).
/// Voice: a warm, brief butler. No theatrics, no "sir".
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
            return "I'm not sure what you'd like me to do with that. You can rephrase it, or turn it into a reminder or note from your book."
        }
        return sentences.joined(separator: " ")
    }

    func when(_ date: Date, includeTime: Bool = true) -> String {
        SpokenFormatter.dateTimePhrase(date, now: now, calendar: calendar, includeTime: includeTime)
    }

    /// Truthful tail for a saved reminder: says nothing when the alert is really scheduled.
    func scheduleTail(_ status: ScheduleStatus) -> String {
        switch status {
        case .scheduled, .repeating, .noAlertNeeded, .unknown: return ""
        case .notificationsDenied: return " It's saved, but notifications are turned off for DayMind, so I can't alert you. You can enable them in Settings."
        case .notDetermined: return " It's saved. Allow notifications so I can alert you at the time."
        case .failed(let why): return " It's saved, but I could not schedule the alert: \(why)"
        }
    }

    func sentence(for record: ActionRecord) -> String? {
        switch record.kind {
        case .reminderCreated(let r):
            var text: String
            if let due = r.dueDate {
                text = "Certainly. \(r.title) — \(when(due))."
                if let rec = r.recurrenceText { text += " Repeats \(rec)." }
            } else {
                text = "Certainly. \(r.title) — no set time."
            }
            if let project = r.projectName { text += " Filed under \(project)." }
            return text + scheduleTail(r.scheduleStatus)
        case .reminderUpdated(let r, let change):
            if let due = r.dueDate, change.hasPrefix("moved") {
                return "Moved. \(r.title) — \(when(due))." + scheduleTail(r.scheduleStatus)
            }
            return "Updated. \(r.title) — \(change)."
        case .reminderCompleted(let r, let next):
            if let next { return "Done. \(r.title). Next one \(when(next))." }
            return "Done. \(r.title)."
        case .reminderDeleted(let title):
            return "Removed \(title)."
        case .reminderSnoozed(let r, let until):
            return "Snoozed. \(r.title) — \(when(until))." + scheduleTail(r.scheduleStatus)
        case .reminderFollowUpSet(let r, let at):
            return "Noted. If \(r.title) isn't done, I'll mention it once more \(when(at))."
        case .remindersDeleted(let count):
            return count == 0 ? "There were no reminders to remove." : "Removed \(count) reminder\(count == 1 ? "" : "s")."
        case .remindersListed(let list, let scope):
            return listSentence(list, scope: scope)
        case .memorySaved(let m):
            var text = "Noted. \(m.content.trimmingCharacters(in: CharacterSet(charactersIn: ".")))."
            if let project = m.projectName { text += " Filed under \(project)." }
            return text
        case .memoryUpdated(let m, let change):
            return "Updated the note “\(m.title)” (\(change))."
        case .memoryDeleted(let title):
            return "Forgotten: “\(title)”."
        case .memoriesDeleted(let count):
            return count == 0 ? "There were no notes to remove." : "Removed \(count) note\(count == 1 ? "" : "s")."
        case .memoriesFound(let list, let query):
            if list.isEmpty { return "I have nothing saved about \(query)." }
            let items = list.prefix(4).map { $0.content.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return "Here's what you told me about \(query): " + items.joined(separator: ". ") + "."
        case .projectCreated(let name):
            return "The project “\(name)” is ready."
        case .itemAssignedToProject(let item, let project):
            return "Filed \(item) under \(project)."
        case .briefing(let text):
            return text
        case .needsConfirmation(let p), .needsChoice(let p):
            return p.question
        case .needsClarification(let q):
            return q
        case .notFound(let what):
            return "I couldn't find \(what), so nothing was changed."
        case .failed(let op, let message):
            return "I couldn't \(op): \(message) Nothing was saved. Your request is kept in your book under Needs attention."
        case .savedToInbox(let reason):
            switch reason {
            case .modelUnavailable, .modelFailed, .ambiguous:
                return "I didn't understand that well enough to act on it. It's kept in your book under Needs attention, where one tap turns it into a reminder or a note."
            default:
                return "I've kept what you said in your book under Needs attention (\(reason.displayName.lowercased()))."
            }
        case .undone(let description):
            return "Undone. \(description)"
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
            return "\(r.title) \(when(due))"
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
