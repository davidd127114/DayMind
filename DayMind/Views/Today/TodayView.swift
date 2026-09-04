import SwiftUI
import Combine
import SwiftData
import DayMindCore

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Query(sort: \Reminder.dueDate, order: .forward) private var allReminders: [Reminder]
    @State private var editing: Reminder?
    @State private var creating = false
    @State private var showCompleted = false
    @State private var now = Date()

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var pending: [Reminder] { allReminders.filter { $0.isPending } }
    private var overdue: [Reminder] { pending.filter { ($0.dueDate ?? .distantFuture) < now } }
    private var today: [Reminder] { pending.filter { r in guard let d = r.dueDate else { return false }; return d >= now && env.settings.calendar.isDate(d, inSameDayAs: now) } }
    private var upcoming: [Reminder] { pending.filter { r in guard let d = r.dueDate else { return false }; return d >= now && !env.settings.calendar.isDate(d, inSameDayAs: now) } }
    private var undated: [Reminder] { pending.filter { $0.dueDate == nil } }
    private var completedRecently: [Reminder] { allReminders.filter { $0.status == .completed }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }.prefix(20).map { $0 } }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if !overdue.isEmpty { section("Overdue", overdue, tint: .red) }
                section("Today", today, tint: .accentColor, emptyText: overdue.isEmpty ? "Nothing else due today." : nil)
                if !upcoming.isEmpty { section("Upcoming", Array(upcoming.prefix(15)), tint: .secondary) }
                if !undated.isEmpty { section("No date", undated, tint: .secondary) }
                if !completedRecently.isEmpty {
                    Section {
                        DisclosureGroup("Completed recently (\(completedRecently.count))", isExpanded: $showCompleted) {
                            ForEach(completedRecently) { r in
                                ReminderRow(reminder: r, now: now, onComplete: { Task { try? await env.reminders.reopen(r) } }, onSnooze: nil)
                                    .onTapGesture { editing = r }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .toolbar {
                SettingsToolbarButton()
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New reminder")
                }
            }
            .sheet(item: $editing) { r in
                NavigationStack { ReminderEditorView(mode: .edit(r)) }
            }
            .sheet(isPresented: $creating) {
                NavigationStack { ReminderEditorView(mode: .create(prefill: nil)) }
            }
            .onReceive(clock) { now = $0 }
            .onAppear { now = Date() }
            .onChange(of: router.reminderToOpen) { _, id in
                guard let id, let r = env.reminders.fetch(id: id) else { return }
                editing = r
                router.reminderToOpen = nil
            }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(env.briefing.headline())
                    .font(.title3.weight(.semibold))
                Text(env.briefing.composeText())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !env.assistant.lastAvailability.isAvailable {
                    Label(env.assistant.lastAvailability.detail, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func section(_ title: String, _ items: [Reminder], tint: Color, emptyText: String? = nil) -> some View {
        Section(title) {
            if items.isEmpty, let emptyText {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(items) { r in
                ReminderRow(reminder: r, now: now,
                            onComplete: { Task { _ = try? await env.reminders.complete(r) } },
                            onSnooze: { interval in Task { _ = try? await env.reminders.snooze(r, by: interval) } })
                    .contentShape(Rectangle())
                    .onTapGesture { editing = r }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { Task { try? await env.reminders.delete(r) } } label: { Label("Delete", systemImage: "trash") }
                        Button { editing = r } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { _ = try? await env.reminders.complete(r) } } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                    }
            }
        }
        .listSectionSeparatorTint(tint)
    }
}

struct ReminderRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reminder: Reminder
    let now: Date
    let onComplete: () -> Void
    let onSnooze: ((TimeInterval) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: reminder.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(reminder.status == .completed ? .green : (reminder.isOverdue(now: now) ? .red : .accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.status == .completed ? "Mark as not done" : "Complete \(reminder.title)")

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(reminder.title)
                        .font(.body.weight(reminder.priority == .high ? .semibold : .regular))
                        .strikethrough(reminder.status == .completed)
                    if reminder.priority == .high {
                        Image(systemName: "exclamationmark").font(.caption).foregroundStyle(.orange).accessibilityLabel("High priority")
                    }
                }
                if let due = reminder.dueDate {
                    HStack(spacing: 6) {
                        Image(systemName: reminder.isRecurring ? "repeat" : "clock").font(.caption2)
                        Text(SpokenFormatter.dateTimePhrase(due, now: now, calendar: env.settings.calendar))
                        if let rule = reminder.recurrence {
                            Text("· \(rule.humanDescription(anchor: nil, calendar: env.settings.calendar))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(reminder.isOverdue(now: now) ? .red : .secondary)
                }
                if !reminder.peopleNames.isEmpty || reminder.project != nil {
                    HStack(spacing: 6) {
                        ForEach(reminder.peopleNames, id: \.self) { Text($0).tagStyle(.blue) }
                        if let p = reminder.project { Text(p.name).tagStyle(.purple) }
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
                    Image(systemName: "zzz").foregroundStyle(.secondary).padding(6)
                }
                .accessibilityLabel("Snooze \(reminder.title)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

extension Text {
    func tagStyle(_ color: Color) -> some View {
        self.font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
