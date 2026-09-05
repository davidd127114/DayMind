import SwiftUI
import DayMindCore

/// The inline card shown after every action: exactly what happened, with Edit / Undo / Done.
/// Undo appears only when the engine has a genuine reversal for this record.
struct ConfirmationCardView: View {
    @Environment(AppEnvironment.self) private var env
    let record: ActionRecord
    var onUndo: ((ActionRecord) -> Void)? = nil
    var onDone: ((UUID) -> Void)? = nil
    var onEditReminder: ((UUID) -> Void)? = nil
    var onEditMemory: ((UUID) -> Void)? = nil
    var onChoose: ((UUID) -> Void)? = nil
    var onConfirm: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private var calendar: Calendar { env.settings.calendar }
    private func when(_ date: Date?) -> String? { date.map { SpokenFormatter.dateTimePhrase($0, now: Date(), calendar: calendar) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 26)
                    .accessibilityHidden(true)
                Text(title).font(.headline).foregroundStyle(ButlerTheme.ink)
                Spacer(minLength: 0)
            }
            content
            controls
        }
        .butlerCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch record.kind {
        case .reminderCreated(let r), .reminderUpdated(let r, _), .reminderSnoozed(let r, _), .reminderFollowUpSet(let r, _), .reminderCompleted(let r, _):
            reminderLines(r)
        case .remindersListed(let list, _):
            if list.isEmpty { Text("Nothing here.").foregroundStyle(ButlerTheme.inkSecondary) }
            ForEach(list.prefix(6)) { r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.title).foregroundStyle(ButlerTheme.ink)
                    Spacer()
                    if let w = when(r.dueDate) { Text(w).foregroundStyle(ButlerTheme.inkSecondary).multilineTextAlignment(.trailing) }
                }
                .font(.subheadline)
            }
            if list.count > 6 { Text("+ \(list.count - 6) more in your book").font(.footnote).foregroundStyle(ButlerTheme.inkSecondary) }
        case .memorySaved(let m), .memoryUpdated(let m, _):
            Text(m.content).font(.subheadline).foregroundStyle(ButlerTheme.ink)
            HStack(spacing: 6) {
                TagView(text: m.category.displayName)
                ForEach(m.people, id: \.self) { TagView(text: $0, systemImage: "person") }
                if let p = m.projectName { TagView(text: p, systemImage: "folder") }
            }
        case .memoriesFound(let list, _):
            if list.isEmpty { Text("Nothing saved about that.").font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary) }
            ForEach(list.prefix(5)) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.content).font(.subheadline).foregroundStyle(ButlerTheme.ink)
                    Text(m.createdAt, style: .date).font(.caption2).foregroundStyle(ButlerTheme.inkSecondary)
                }
                .padding(.vertical, 2)
            }
        case .briefing(let text), .undone(let text):
            Text(text).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .needsConfirmation(let p), .needsChoice(let p):
            Text(p.question).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .needsClarification(let q):
            Text(q).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .failed(_, let message):
            Text(message).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .notFound(let what):
            Text("Nothing matched \(what).").font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .savedToInbox:
            Text("Open My Book › Needs attention to turn it into a reminder or a note.").font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .reminderDeleted(let t), .memoryDeleted(let t):
            Text(t).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .remindersDeleted(let n), .memoriesDeleted(let n):
            Text("\(n) removed").font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .projectCreated(let n):
            Text(n).font(.subheadline).foregroundStyle(ButlerTheme.ink)
        case .itemAssignedToProject(let i, let p):
            Text("\(i) → \(p)").font(.subheadline).foregroundStyle(ButlerTheme.ink)
        }
    }

    @ViewBuilder
    private func reminderLines(_ r: ReminderSummary) -> some View {
        Text(r.title).font(.title3.weight(.semibold)).foregroundStyle(ButlerTheme.ink)
        if let w = when(r.dueDate) {
            Label(w, systemImage: "clock").font(.subheadline).foregroundStyle(ButlerTheme.ink)
        } else {
            Label("No set time", systemImage: "clock").font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
        }
        if let rec = r.recurrenceText { Label(rec, systemImage: "repeat").font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary) }
        if !r.people.isEmpty || r.projectName != nil {
            HStack(spacing: 6) {
                ForEach(r.people, id: \.self) { TagView(text: $0, systemImage: "person") }
                if let p = r.projectName { TagView(text: p, systemImage: "folder") }
            }
        }
        scheduleLine(r.scheduleStatus, isPending: r.status == .pending, hasDate: r.dueDate != nil)
    }

    @ViewBuilder
    private func scheduleLine(_ status: ScheduleStatus, isPending: Bool, hasDate: Bool) -> some View {
        if isPending, hasDate {
            switch status {
            case .scheduled: Label("Alert scheduled", systemImage: "bell.badge.fill").font(.caption).foregroundStyle(ButlerTheme.success)
            case .repeating: Label("Repeating alert scheduled", systemImage: "bell.badge.fill").font(.caption).foregroundStyle(ButlerTheme.success)
            case .notificationsDenied: Label("Saved, but notifications are off for DayMind", systemImage: "bell.slash.fill").font(.caption).foregroundStyle(ButlerTheme.attention)
            case .notDetermined: Label("Saved. Allow notifications to be alerted", systemImage: "bell").font(.caption).foregroundStyle(ButlerTheme.attention)
            case .failed(let why): Label("Saved, but the alert could not be scheduled: \(why)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(ButlerTheme.failure)
            case .noAlertNeeded, .unknown: EmptyView()
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch record.kind {
        case .needsChoice(.chooseReminder(let candidates, _)):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(candidates) { c in
                    Button { onChoose?(c.id) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.title).foregroundStyle(ButlerTheme.ink)
                                if let w = when(c.dueDate) { Text(w).font(.caption).foregroundStyle(ButlerTheme.inkSecondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(ButlerTheme.inkSecondary)
                        }
                        .padding(10)
                        .background(ButlerTheme.ivory, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                Button("Cancel", role: .cancel) { onCancel?() }.font(.subheadline)
            }
        case .needsConfirmation(let p):
            HStack {
                Button(role: p.isDestructive ? .destructive : nil) { onConfirm?() } label: {
                    Label(p.isDestructive ? "Yes, delete" : "Yes", systemImage: p.isDestructive ? "trash" : "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(p.isDestructive ? ButlerTheme.failure : ButlerTheme.gold)
                Button { onCancel?() } label: { Label("No", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(ButlerTheme.ink)
            }
        default:
            HStack(spacing: 10) {
                if let id = record.reminderID, let onEditReminder {
                    Button { onEditReminder(id) } label: { Label("Edit", systemImage: "pencil") }
                }
                if let id = record.memoryID, let onEditMemory {
                    Button { onEditMemory(id) } label: { Label("Edit", systemImage: "pencil") }
                }
                if let onUndo, env.assistant.canUndo(record) {
                    Button { onUndo(record) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                }
                if case .reminderCreated(let r) = record.kind, r.status == .pending, let onDone {
                    Button { onDone(r.id) } label: { Label("Done", systemImage: "checkmark") }
                } else if case .reminderUpdated(let r, _) = record.kind, r.status == .pending, let onDone {
                    Button { onDone(r.id) } label: { Label("Done", systemImage: "checkmark") }
                } else if case .reminderSnoozed(let r, _) = record.kind, let onDone {
                    Button { onDone(r.id) } label: { Label("Done", systemImage: "checkmark") }
                }
            }
            .buttonStyle(.bordered)
            .tint(ButlerTheme.ink)
            .controlSize(.small)
            .font(.subheadline)
        }
    }

    // MARK: Titles, icons, tints

    private var title: String {
        switch record.kind {
        case .reminderCreated: return "Reminder saved"
        case .reminderUpdated(_, let change): return change.hasPrefix("moved") ? "Reminder moved" : "Reminder updated"
        case .reminderCompleted(_, let next): return next == nil ? "Done" : "Done — next one scheduled"
        case .reminderDeleted: return "Reminder removed"
        case .reminderSnoozed(_, let until): return "Snoozed until \(when(until) ?? "")"
        case .reminderFollowUpSet(_, let at): return "Will mention again \(when(at) ?? "")"
        case .remindersDeleted: return "Reminders removed"
        case .remindersListed(let l, let scope): return "\(l.count) reminder\(l.count == 1 ? "" : "s") · \(scopeName(scope))"
        case .memorySaved: return "Noted"
        case .memoryUpdated: return "Note updated"
        case .memoryDeleted: return "Note removed"
        case .memoriesDeleted: return "Notes removed"
        case .memoriesFound(let l, let q): return l.isEmpty ? "Nothing about “\(q)”" : "What you told me about “\(q)”"
        case .projectCreated: return "Project ready"
        case .itemAssignedToProject: return "Filed"
        case .briefing: return "Your day"
        case .needsConfirmation: return "Please confirm"
        case .needsChoice: return "Which one?"
        case .needsClarification: return "One question"
        case .notFound: return "Not found"
        case .failed(let op, _): return "Couldn't \(op) — nothing saved"
        case .savedToInbox: return "Kept for you to finish"
        case .undone: return "Undone"
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
        case .memorySaved, .memoryUpdated: return "book.closed"
        case .memoriesFound: return "magnifyingglass"
        case .projectCreated, .itemAssignedToProject: return "folder"
        case .briefing: return "sun.max"
        case .needsConfirmation, .needsChoice, .needsClarification: return "questionmark.circle"
        case .notFound: return "questionmark.folder"
        case .failed: return "xmark.octagon"
        case .savedToInbox: return "tray.and.arrow.down"
        case .undone: return "arrow.uturn.backward"
        }
    }

    private var tint: Color {
        switch record.kind {
        case .failed: return ButlerTheme.failure
        case .notFound, .savedToInbox, .needsConfirmation, .needsChoice, .needsClarification: return ButlerTheme.attention
        case .reminderCompleted, .undone: return ButlerTheme.success
        default: return ButlerTheme.gold
        }
    }
}
