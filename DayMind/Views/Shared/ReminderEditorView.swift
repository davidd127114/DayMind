import SwiftUI
import SwiftData
import DayMindCore

/// Deterministic reminder form. Works with no AI at all; the "Understand this" field uses the
/// offline rule-based parser to pre-fill the fields.
struct ReminderEditorView: View {
    enum Mode {
        case create(prefill: ReminderDraft?)
        case edit(Reminder)
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]

    let mode: Mode
    var onSaved: ((Reminder) -> Void)? = nil
    var inboxItemToResolve: InboxItem? = nil

    @State private var quickText = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDate = true
    @State private var dueDate = Date().addingTimeInterval(3600)
    @State private var repeats = false
    @State private var frequency: RecurrenceRule.Frequency = .weekly
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var monthlyMode = 0 // 0 = same day of month, 1 = nth weekday
    @State private var weekOfMonth = 1
    @State private var priority: ReminderPriority = .normal
    @State private var peopleText = ""
    @State private var projectID: UUID?
    @State private var followUp = false
    @State private var followUpDate = Date().addingTimeInterval(86_400)
    @State private var error: String?
    @State private var duplicate: ReminderSummary?
    @State private var saving = false

    private var calendar: Calendar { env.settings.calendar }

    var body: some View {
        Form {
            if case .create = mode {
                Section("Say it in words (optional)") {
                    TextField("e.g. Remind me tomorrow at 3 PM to call Michael", text: $quickText, axis: .vertical)
                    Button("Understand this") { interpretQuickText() }
                        .disabled(quickText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Reminder") {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes, axis: .vertical)
                Picker("Priority", selection: $priority) {
                    ForEach(ReminderPriority.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("When") {
                Toggle("Has a date and time", isOn: $hasDate)
                if hasDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, env.settings.timeZone)
                    Toggle("Repeats", isOn: $repeats)
                    if repeats { recurrenceFields }
                    Toggle("Remind me again if not completed", isOn: $followUp)
                    if followUp {
                        DatePicker("Follow-up", selection: $followUpDate, in: dueDate..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            Section("Related") {
                TextField("People (comma separated)", text: $peopleText)
                Picker("Project", selection: $projectID) {
                    Text("None").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if case .edit(let r) = mode {
                Section {
                    if let transcript = r.originalTranscript {
                        LabeledContent("Original words", value: transcript)
                    }
                    if !r.snoozeHistory.isEmpty {
                        Text("Snoozed \(r.snoozeHistory.count) time\(r.snoozeHistory.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                    Button("Delete reminder", role: .destructive) {
                        Task { try? await env.reminders.delete(r); dismiss() }
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(isEditing ? "Edit Reminder" : "New Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") { Task { await save(allowDuplicate: false) } }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .alert("Similar reminder exists", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } })) {
            Button("Add anyway") { Task { await save(allowDuplicate: true) } }
            Button("Cancel", role: .cancel) { duplicate = nil }
        } message: {
            Text("You already have “\(duplicate?.title ?? "")”\(duplicate?.dueDate.map { " \(SpokenFormatter.dateTimePhrase($0, now: Date(), calendar: calendar))" } ?? ""). Add this one too?")
        }
        .onAppear(perform: load)
    }

    private var isEditing: Bool { if case .edit = mode { return true }; return false }

    @ViewBuilder
    private var recurrenceFields: some View {
        Picker("Frequency", selection: $frequency) {
            ForEach(RecurrenceRule.Frequency.allCases) { Text($0.displayName).tag($0) }
        }
        Stepper("Every \(interval) \(unitName)", value: $interval, in: 1...30)
        if frequency == .weekly {
            WeekdayPicker(selection: $weekdays, calendar: calendar)
        }
        if frequency == .monthly {
            Picker("On", selection: $monthlyMode) {
                Text("Day \(calendar.component(.day, from: dueDate)) of the month").tag(0)
                Text("The \(RecurrenceRule.ordinalName(weekOfMonth)) \(RecurrenceRule.weekdayName(calendar.component(.weekday, from: dueDate), calendar: calendar))").tag(1)
            }
            if monthlyMode == 1 {
                Picker("Which", selection: $weekOfMonth) {
                    Text("First").tag(1); Text("Second").tag(2); Text("Third").tag(3); Text("Fourth").tag(4); Text("Last").tag(-1)
                }
            }
        }
        Text(currentRule?.humanDescription(anchor: dueDate, calendar: calendar) ?? "")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var unitName: String {
        switch frequency {
        case .daily: return interval == 1 ? "day" : "days"
        case .weekly: return interval == 1 ? "week" : "weeks"
        case .monthly: return interval == 1 ? "month" : "months"
        case .yearly: return interval == 1 ? "year" : "years"
        }
    }

    private var currentRule: RecurrenceRule? {
        guard repeats, hasDate else { return nil }
        switch frequency {
        case .daily: return RecurrenceRule(frequency: .daily, interval: interval)
        case .weekly: return RecurrenceRule(frequency: .weekly, interval: interval, weekdays: Array(weekdays))
        case .monthly:
            if monthlyMode == 1 { return RecurrenceRule(frequency: .monthly, interval: interval, weekdays: [calendar.component(.weekday, from: dueDate)], weekOfMonth: weekOfMonth) }
            return RecurrenceRule(frequency: .monthly, interval: interval, dayOfMonth: calendar.component(.day, from: dueDate))
        case .yearly: return RecurrenceRule(frequency: .yearly, interval: interval, dayOfMonth: calendar.component(.day, from: dueDate), monthOfYear: calendar.component(.month, from: dueDate))
        }
    }

    private func load() {
        switch mode {
        case .create(let prefill):
            if let prefill { apply(draft: prefill) } else {
                let base = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                dueDate = calendar.date(bySetting: .minute, value: 0, of: base) ?? base
            }
        case .edit(let r):
            title = r.title
            notes = r.notes
            hasDate = r.dueDate != nil
            dueDate = r.dueDate ?? Date()
            priority = r.priority
            peopleText = r.peopleNames.joined(separator: ", ")
            projectID = r.project?.id
            followUp = r.followUpDate != nil
            followUpDate = r.followUpDate ?? dueDate.addingTimeInterval(86_400)
            if let rule = r.recurrence {
                repeats = true
                frequency = rule.frequency
                interval = rule.interval
                weekdays = Set(rule.weekdays)
                if let w = rule.weekOfMonth { monthlyMode = 1; weekOfMonth = w }
            }
        }
    }

    private func apply(draft: ReminderDraft) {
        title = draft.title
        notes = draft.notes
        priority = draft.priority
        peopleText = draft.people.joined(separator: ", ")
        if let name = draft.projectName, let p = env.projects.find(name: name) { projectID = p.id }
        if let due = draft.dueDate { hasDate = true; dueDate = due } else { hasDate = false }
        if let rule = draft.recurrence {
            repeats = true
            frequency = rule.frequency
            interval = rule.interval
            weekdays = Set(rule.weekdays)
            if let w = rule.weekOfMonth { monthlyMode = 1; weekOfMonth = w } else { monthlyMode = 0 }
        } else {
            repeats = false
        }
        if let question = draft.clarificationQuestion { error = question }
    }

    private func interpretQuickText() {
        let interpreter = RuleBasedInterpreter(calendar: calendar, now: Date(), defaults: env.settings.timeDefaults)
        switch interpreter.interpret(quickText) {
        case .createReminder(let d), .createReminderAndMemory(let d, _):
            error = nil
            apply(draft: d)
        default:
            if let d = interpreter.parseReminder(NaturalDateParser.normalize(quickText)) {
                error = nil
                apply(draft: d)
            } else {
                error = "I couldn't turn that into a reminder. Fill in the fields below."
                title = quickText
            }
        }
    }

    private func save(allowDuplicate: Bool) async {
        saving = true
        defer { saving = false }
        error = nil
        let people = peopleText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let projectName = projectID.flatMap { env.projects.fetch(id: $0)?.name }
        do {
            switch mode {
            case .create:
                let draft = ReminderDraft(title: title, notes: notes, dueDate: hasDate ? dueDate : nil, hasExplicitTime: hasDate, recurrence: currentRule,
                                          priority: priority, people: people, projectName: projectName)
                let r = try await env.reminders.create(from: draft, transcript: quickText.isEmpty ? nil : quickText, allowDuplicate: allowDuplicate)
                if followUp, hasDate { try await env.reminders.setFollowUp(r, at: followUpDate) }
                if let inboxItemToResolve { env.inbox.markResolved(inboxItemToResolve) }
                onSaved?(r)
            case .edit(let r):
                try await env.reminders.apply(ReminderChanges(title: title, notes: notes, dueDate: .some(hasDate ? dueDate : nil), recurrence: .some(currentRule),
                                                              priority: priority, people: people, projectName: .some(projectName)), to: r)
                try await env.reminders.setFollowUp(r, at: (followUp && hasDate) ? followUpDate : nil)
                onSaved?(r)
            }
            dismiss()
        } catch ReminderServiceError.possibleDuplicate(let id, _) {
            if let existing = env.reminders.fetch(id: id) { duplicate = env.reminders.summary(existing) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 6) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var orderedWeekdays: [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }
}
