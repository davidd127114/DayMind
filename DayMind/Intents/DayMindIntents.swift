import AppIntents
import Foundation
import DayMindCore

/// "Add a reminder in DayMind". Runs in the app process; uses the same validated service path.
struct AddReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Reminder"
    static let description = IntentDescription("Creates a reminder in DayMind. Works without Apple Intelligence.")

    @Parameter(title: "Reminder", requestValueDialog: "What should I remind you about?")
    var text: String

    @Parameter(title: "When", requestValueDialog: "When should I remind you?")
    var when: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me to \(\.$text) at \(\.$when)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        let interpreter = RuleBasedInterpreter(calendar: env.settings.calendar, now: Date(), defaults: env.settings.timeDefaults)
        var draft: ReminderDraft
        if case .createReminder(let d) = interpreter.interpret(text) {
            draft = d
        } else if let d = interpreter.parseReminder(NaturalDateParser.normalize("remind me to " + text)) {
            draft = d
        } else {
            draft = ReminderDraft(title: text)
        }
        if let when { draft.dueDate = when; draft.hasExplicitTime = true; draft.clarificationQuestion = nil }
        guard draft.dueDate != nil || draft.recurrence != nil else {
            let saved = env.inbox.add(text: text, source: .shortcut, reason: .ambiguous, detail: "No date was given.")
            _ = saved
            return .result(dialog: "I need a time for that. I saved it to your DayMind Inbox so you can finish it there.")
        }
        do {
            let reminder = try await env.reminders.create(from: draft, transcript: text, allowDuplicate: true)
            let phrase = SpokenFormatter.reminderConfirmation(title: reminder.title, date: reminder.dueDate, recurrence: reminder.recurrence, now: Date(), calendar: env.settings.calendar)
            return .result(dialog: IntentDialog(stringLiteral: phrase))
        } catch {
            env.inbox.add(text: text, source: .shortcut, reason: .toolFailed, detail: error.localizedDescription)
            return .result(dialog: "I couldn't save that reminder, so I kept it in your DayMind Inbox.")
        }
    }
}

struct SaveMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Save a Memory"
    static let description = IntentDescription("Remembers a fact, preference or note permanently in DayMind.")

    @Parameter(title: "What to remember", requestValueDialog: "What should I remember?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        let interpreter = RuleBasedInterpreter(calendar: env.settings.calendar, now: Date(), defaults: env.settings.timeDefaults)
        let draft: MemoryDraft
        if case .saveMemory(let m) = interpreter.interpret("remember that " + text) {
            draft = m
        } else {
            draft = MemoryDraft(title: RuleBasedInterpreter.summaryTitle(text), content: text)
        }
        do {
            let memory = try env.memories.create(from: draft, transcript: text)
            return .result(dialog: IntentDialog(stringLiteral: "Got it. I'll remember that \(SpokenFormatter.lowercaseFirst(memory.content))"))
        } catch {
            env.inbox.add(text: text, source: .shortcut, reason: .toolFailed, detail: error.localizedDescription)
            return .result(dialog: "I couldn't save that, so I kept it in your DayMind Inbox.")
        }
    }
}

struct TodayBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Briefing"
    static let description = IntentDescription("Hear today's reminders, overdue items and what's coming up.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = AppEnvironment.shared.briefing.composeText()
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct NextDueIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due Next"
    static let description = IntentDescription("Tells you the next reminder that is due.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = AppEnvironment.shared
        let now = Date()
        let pending = env.reminders.pending().filter { $0.dueDate != nil }
        let overdue = pending.filter { ($0.dueDate ?? now) < now }
        if let first = overdue.first {
            let extra = overdue.count > 1 ? " and \(overdue.count - 1) more overdue" : ""
            return .result(dialog: IntentDialog(stringLiteral: "Overdue: \(first.title), was due \(SpokenFormatter.dateTimePhrase(first.dueDate ?? now, now: now, calendar: env.settings.calendar))\(extra)."))
        }
        guard let next = pending.first(where: { ($0.dueDate ?? now) >= now }), let due = next.dueDate else {
            return .result(dialog: "Nothing is scheduled. You're all caught up.")
        }
        return .result(dialog: IntentDialog(stringLiteral: "Next up: \(next.title) \(SpokenFormatter.dateTimePhrase(due, now: now, calendar: env.settings.calendar))."))
    }
}

/// Phrases Siri and the Shortcuts app expose without any setup. Also what the Action Button uses.
struct DayMindShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenVoiceCaptureIntent(),
                    phrases: ["Talk to \(.applicationName)", "Open \(.applicationName) voice", "Start listening in \(.applicationName)"],
                    shortTitle: "Talk to DayMind",
                    systemImageName: "mic.fill")
        AppShortcut(intent: AddReminderIntent(),
                    phrases: ["Add a reminder in \(.applicationName)", "New \(.applicationName) reminder"],
                    shortTitle: "Add Reminder",
                    systemImageName: "bell.badge")
        AppShortcut(intent: SaveMemoryIntent(),
                    phrases: ["Save a memory in \(.applicationName)", "Remember this in \(.applicationName)"],
                    shortTitle: "Save Memory",
                    systemImageName: "brain")
        AppShortcut(intent: TodayBriefingIntent(),
                    phrases: ["\(.applicationName) briefing", "What's my day in \(.applicationName)"],
                    shortTitle: "Today's Briefing",
                    systemImageName: "sun.max")
        AppShortcut(intent: NextDueIntent(),
                    phrases: ["What's next in \(.applicationName)", "What's due in \(.applicationName)"],
                    shortTitle: "What's Due Next",
                    systemImageName: "clock")
    }
}
