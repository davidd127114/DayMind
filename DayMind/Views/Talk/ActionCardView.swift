import SwiftUI
import DayMindCore

/// Shows exactly what was saved, changed, found — or why nothing happened.
struct ActionCardView: View {
    @Environment(AppEnvironment.self) private var env
    let record: ActionRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    private var calendar: Calendar { env.settings.calendar }

    private func when(_ date: Date?) -> String? {
        date.map { SpokenFormatter.dateTimePhrase($0, now: Date(), calendar: calendar) }
    }

    @ViewBuilder
    private var content: some View {
        switch record.kind {
        case .reminderCreated(let r), .reminderUpdated(let r, _), .reminderSnoozed(let r, _), .reminderFollowUpSet(let r, _), .reminderCompleted(let r, _):
            reminderLines(r)
        case .remindersListed(let list, _):
            if list.isEmpty { Text("Nothing here.").foregroundStyle(.secondary) }
            ForEach(list.prefix(8)) { r in
                HStack {
                    Text(r.title)
                    Spacer()
                    if let w = when(r.dueDate) { Text(w).foregroundStyle(.secondary) }
                }
                .font(.footnote)
            }
            if list.count > 8 { Text("+ \(list.count - 8) more").font(.footnote).foregroundStyle(.secondary) }
        case .memorySaved(let m), .memoryUpdated(let m, _):
            Text(m.content).font(.footnote)
            HStack(spacing: 6) {
                Text(m.category.displayName).tagStyle(.teal)
                ForEach(m.people, id: \.self) { Text($0).tagStyle(.blue) }
                if let p = m.projectName { Text(p).tagStyle(.purple) }
            }
        case .memoriesFound(let list, _):
            if list.isEmpty { Text("Nothing saved about that.").foregroundStyle(.secondary).font(.footnote) }
            ForEach(list.prefix(6)) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.content).font(.footnote)
                    Text(m.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        case .briefing(let text):
            Text(text).font(.footnote)
        case .needsConfirmation(let p), .needsChoice(let p):
            Text(p.question).font(.footnote)
        case .needsClarification(let q):
            Text(q).font(.footnote)
        case .failed(_, let message):
            Text(message).font(.footnote)
        case .notFound(let what):
            Text("Nothing matched \(what).").font(.footnote)
        case .savedToInbox(let reason):
            Text(reason.displayName).font(.footnote)
        case .reminderDeleted(let t), .memoryDeleted(let t):
            Text(t).font(.footnote)
        case .remindersDeleted(let n), .memoriesDeleted(let n):
            Text("\(n) removed").font(.footnote)
        case .projectCreated(let n):
            Text(n).font(.footnote)
        case .itemAssignedToProject(let i, let p):
            Text("\(i) → \(p)").font(.footnote)
        }
    }

    @ViewBuilder
    private func reminderLines(_ r: ReminderSummary) -> some View {
        Text(r.title).font(.footnote)
        if let w = when(r.dueDate) { Label(w, systemImage: "clock").font(.footnote).foregroundStyle(.secondary) }
        if let rec = r.recurrenceText { Label(rec, systemImage: "repeat").font(.footnote).foregroundStyle(.secondary) }
        if !r.people.isEmpty || r.projectName != nil {
            HStack(spacing: 6) {
                ForEach(r.people, id: \.self) { Text($0).tagStyle(.blue) }
                if let p = r.projectName { Text(p).tagStyle(.purple) }
            }
        }
    }

    private var title: String {
        switch record.kind {
        case .reminderCreated: return "Reminder saved"
        case .reminderUpdated(_, let change): return "Reminder \(change)"
        case .reminderCompleted(_, let next): return next == nil ? "Completed" : "Completed — next occurrence scheduled"
        case .reminderDeleted: return "Reminder deleted"
        case .reminderSnoozed(_, let until): return "Snoozed until \(when(until) ?? "")"
        case .reminderFollowUpSet(_, let at): return "Follow-up \(when(at) ?? "")"
        case .remindersDeleted: return "Reminders deleted"
        case .remindersListed(let l, let scope): return "\(l.count) reminder\(l.count == 1 ? "" : "s") · \(scopeName(scope))"
        case .memorySaved: return "Memory saved"
        case .memoryUpdated(_, let change): return "Memory \(change)"
        case .memoryDeleted: return "Memory deleted"
        case .memoriesDeleted: return "Memories deleted"
        case .memoriesFound(let l, let q): return "\(l.count) memor\(l.count == 1 ? "y" : "ies") about “\(q)”"
        case .projectCreated: return "Project"
        case .itemAssignedToProject: return "Filed under project"
        case .briefing: return "Briefing"
        case .needsConfirmation: return "Please confirm"
        case .needsChoice: return "Please choose"
        case .needsClarification: return "One question"
        case .notFound: return "Not found"
        case .failed(let op, _): return "Could not \(op) — nothing saved"
        case .savedToInbox: return "Kept in Inbox"
        }
    }

    private func scopeName(_ scope: ReminderListScope) -> String {
        switch scope {
        case .today: return "today"
        case .overdue: return "overdue"
        case .upcoming: return "upcoming"
        case .tomorrow: return "tomorrow"
        case .thisWeek: return "this week"
        case .forgottenYesterday: return "missed yesterday"
        case .all: return "all"
        }
    }

    private var icon: String {
        switch record.kind {
        case .reminderCreated, .reminderUpdated, .reminderSnoozed, .reminderFollowUpSet: return "bell.badge"
        case .reminderCompleted: return "checkmark.circle"
        case .reminderDeleted, .remindersDeleted, .memoryDeleted, .memoriesDeleted: return "trash"
        case .remindersListed: return "list.bullet"
        case .memorySaved, .memoryUpdated: return "brain"
        case .memoriesFound: return "magnifyingglass"
        case .projectCreated, .itemAssignedToProject: return "folder"
        case .briefing: return "sun.max"
        case .needsConfirmation, .needsChoice, .needsClarification: return "questionmark.circle"
        case .notFound: return "questionmark.folder"
        case .failed: return "xmark.octagon"
        case .savedToInbox: return "tray.and.arrow.down"
        }
    }

    private var tint: Color {
        switch record.kind {
        case .failed: return .red
        case .notFound, .savedToInbox, .needsConfirmation, .needsChoice, .needsClarification: return .orange
        case .reminderCompleted: return .green
        case .memorySaved, .memoryUpdated, .memoriesFound: return .teal
        default: return .accentColor
        }
    }
}
