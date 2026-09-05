import SwiftUI
import DayMindCore

/// One reminder in a list, with complete and snooze controls.
struct ReminderRow: View {
    @Environment(AppEnvironment.self) private var env
    let reminder: Reminder
    let now: Date
    let onComplete: () -> Void
    let onSnooze: ((TimeInterval) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: reminder.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(reminder.status == .completed ? ButlerTheme.success : (reminder.isOverdue(now: now) ? ButlerTheme.failure : ButlerTheme.gold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.status == .completed ? "Mark \(reminder.title) as not done" : "Complete \(reminder.title)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reminder.title)
                        .font(.body.weight(reminder.priority == .high ? .semibold : .regular))
                        .strikethrough(reminder.status == .completed)
                        .foregroundStyle(ButlerTheme.ink)
                    if reminder.priority == .high {
                        Image(systemName: "exclamationmark").font(.caption).foregroundStyle(ButlerTheme.attention).accessibilityLabel("High priority")
                    }
                }
                if let due = reminder.dueDate {
                    HStack(spacing: 6) {
                        Image(systemName: reminder.isRecurring ? "repeat" : "clock").font(.caption2)
                        Text(SpokenFormatter.dateTimePhrase(due, now: now, calendar: env.settings.calendar))
                        if let rule = reminder.recurrence {
                            Text("· \(rule.humanDescription(anchor: nil, calendar: env.settings.calendar))")
                        }
                        if reminder.isOverdue(now: now) { Text("· overdue") }
                    }
                    .font(.caption)
                    .foregroundStyle(reminder.isOverdue(now: now) ? ButlerTheme.failure : ButlerTheme.inkSecondary)
                } else {
                    Text("No set time").font(.caption).foregroundStyle(ButlerTheme.inkSecondary)
                }
                if !reminder.peopleNames.isEmpty || reminder.project != nil {
                    HStack(spacing: 6) {
                        ForEach(reminder.peopleNames, id: \.self) { TagView(text: $0, systemImage: "person") }
                        if let p = reminder.project { TagView(text: p.name, systemImage: "folder") }
                    }
                }
            }
            Spacer(minLength: 0)
            if let onSnooze, reminder.isPending {
                Menu {
                    Button("Snooze 1 hour") { onSnooze(3600) }
                    Button("Snooze 3 hours") { onSnooze(3 * 3600) }
                    Button("Snooze until tomorrow") { onSnooze(86_400) }
                } label: {
                    Image(systemName: "zzz").foregroundStyle(ButlerTheme.inkSecondary).padding(6)
                }
                .accessibilityLabel("Snooze \(reminder.title)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

/// One memory in a list.
struct MemoryRow: View {
    let memory: Memory
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: memory.category.systemImageName).foregroundStyle(ButlerTheme.gold)
                Text(memory.title).font(.body.weight(.medium)).foregroundStyle(ButlerTheme.ink)
                if memory.importance == .high { Image(systemName: "star.fill").font(.caption).foregroundStyle(ButlerTheme.gold).accessibilityLabel("Important") }
                if memory.isArchived { TagView(text: "Archived") }
            }
            Text(memory.content).font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary).lineLimit(3)
            HStack(spacing: 6) {
                TagView(text: memory.category.displayName)
                ForEach(memory.peopleNames, id: \.self) { TagView(text: $0, systemImage: "person") }
                if let p = memory.project { TagView(text: p.name, systemImage: "folder") }
                ForEach(memory.tags, id: \.self) { TagView(text: "#\($0)") }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
