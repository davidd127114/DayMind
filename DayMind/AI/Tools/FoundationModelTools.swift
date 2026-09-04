import Foundation
import DayMindCore

#if canImport(FoundationModels)
import FoundationModels

// Strictly typed tools exposed to the on-device Apple model. Each tool only forwards validated
// arguments to `AssistantActions`; the model never touches the database directly.
//
// Dates and recurrence are passed as the *words the user said* ("next friday", "3 pm",
// "every first monday of the month"). Deterministic Swift code turns them into exact dates, because
// small on-device models are unreliable at calendar arithmetic.

@available(iOS 26.0, *)
struct CreateReminderTool: Tool {
    let name = "createReminder"
    let description = "Create a new reminder for something the user must do at a time, on a date, or on a repeating schedule."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Short imperative title, e.g. 'Call Michael' or 'Pay rent'")
        var title: String
        @Guide(description: "Date words exactly as the user said them: 'tomorrow', 'next friday', 'september 11', '2026-09-11'. Empty string if no date was said.")
        var dateExpression: String
        @Guide(description: "Time words as the user said them: '3 pm', '15:00', 'morning', 'noon'. Empty string if no time was said.")
        var timeExpression: String
        @Guide(description: "Repeat pattern as the user said it: 'every monday', 'every first monday of the month', 'daily', 'every weekday'. Empty string if it does not repeat.")
        var recurrenceExpression: String
        @Guide(description: "Names of people involved, e.g. ['Michael']. Empty list if none.")
        var people: [String]
        @Guide(description: "Project name if the user mentioned one, otherwise empty string.")
        var projectName: String
        @Guide(description: "Priority", .anyOf(["low", "normal", "high"]))
        var priority: String
        @Guide(description: "Extra details worth keeping, or empty string.")
        var notes: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.createReminder(title: arguments.title, dateExpression: arguments.dateExpression, timeExpression: arguments.timeExpression,
                                     recurrenceExpression: arguments.recurrenceExpression, notes: arguments.notes, people: arguments.people,
                                     projectName: arguments.projectName, priority: arguments.priority)
    }
}

@available(iOS 26.0, *)
struct UpdateReminderTool: Tool {
    let name = "updateReminder"
    let description = "Change an existing reminder: move it to a new date or time, rename it, change its notes or priority."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which reminder, e.g. 'plumber', 'tomorrow's call'. Use 'that' when the user refers to the reminder just discussed.")
        var reminderQuery: String
        @Guide(description: "New date words as said ('friday', 'next week', '2026-09-11') or empty string to keep the date.")
        var newDateExpression: String
        @Guide(description: "New time words as said ('10 am', '15:30') or empty string to keep the time.")
        var newTimeExpression: String
        @Guide(description: "New title, or empty string to keep it.")
        var newTitle: String
        @Guide(description: "New notes, or empty string to keep them.")
        var newNotes: String
        @Guide(description: "New priority or empty string", .anyOf(["", "low", "normal", "high"]))
        var newPriority: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.updateReminder(query: arguments.reminderQuery, id: nil, newTitle: arguments.newTitle, newDateExpression: arguments.newDateExpression,
                                     newTimeExpression: arguments.newTimeExpression, newNotes: arguments.newNotes, newPriority: arguments.newPriority)
    }
}

@available(iOS 26.0, *)
struct CompleteReminderTool: Tool {
    let name = "completeReminder"
    let description = "Mark a reminder as done. Repeating reminders advance to their next occurrence."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which reminder, or 'that' for the reminder just discussed.")
        var reminderQuery: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.completeReminder(query: arguments.reminderQuery, id: nil)
    }
}

@available(iOS 26.0, *)
struct DeleteReminderTool: Tool {
    let name = "deleteReminder"
    let description = "Delete one reminder, or request deletion of all reminders (the app will ask the user to confirm bulk deletion)."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which reminder, or 'that'. Ignored when deleteAll is true.")
        var reminderQuery: String
        @Guide(description: "true only if the user explicitly asked to delete ALL reminders.")
        var deleteAll: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.deleteReminder(query: arguments.reminderQuery, id: nil, deleteAll: arguments.deleteAll)
    }
}

@available(iOS 26.0, *)
struct SnoozeReminderTool: Tool {
    let name = "snoozeReminder"
    let description = "Postpone a reminder by a number of minutes (e.g. 'snooze that for two hours' → 120)."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which reminder, or 'that' for the reminder just discussed.")
        var reminderQuery: String
        @Guide(description: "How many minutes to postpone. Two hours = 120, one day = 1440.", .range(1...43200))
        var minutes: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.snoozeReminder(query: arguments.reminderQuery, id: nil, minutes: arguments.minutes)
    }
}

@available(iOS 26.0, *)
struct ListRemindersTool: Tool {
    let name = "listReminders"
    let description = "List the user's reminders for a time range. Use 'today' for 'what do I need to do today' or 'what am I forgetting', 'forgottenYesterday' for tasks missed yesterday."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Which reminders to list", .anyOf(["today", "overdue", "upcoming", "tomorrow", "thisWeek", "forgottenYesterday", "all"]))
        var scope: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.listReminders(scope: ReminderListScope(rawValue: arguments.scope) ?? .today)
    }
}

@available(iOS 26.0, *)
struct SaveMemoryTool: Tool {
    let name = "saveMemory"
    let description = "Permanently remember a fact, preference, decision, idea or detail about a person or project. Not for things that need a reminder at a time."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "The fact to remember, written as a complete sentence in the user's words, e.g. 'Michael prefers afternoon appointments.'")
        var content: String
        @Guide(description: "Very short title (max 8 words).")
        var title: String
        @Guide(description: "Category", .anyOf(["fact", "preference", "decision", "person", "project", "idea", "health", "place", "other"]))
        var category: String
        @Guide(description: "Names of people this is about. Empty list if none.")
        var people: [String]
        @Guide(description: "Project name if the user mentioned one, otherwise empty string.")
        var projectName: String
        @Guide(description: "Up to 3 short lowercase tags. Empty list if none.", .maximumCount(3))
        var tags: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.saveMemory(title: arguments.title, content: arguments.content, category: arguments.category, people: arguments.people,
                                 projectName: arguments.projectName, tags: arguments.tags, importance: "normal")
    }
}

@available(iOS 26.0, *)
struct UpdateMemoryTool: Tool {
    let name = "updateMemory"
    let description = "Edit or archive an existing memory."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which memory, or 'that' for the most recent one.")
        var memoryQuery: String
        @Guide(description: "New content, or empty string to keep it.")
        var newContent: String
        @Guide(description: "New title, or empty string to keep it.")
        var newTitle: String
        @Guide(description: "true to archive the memory (hide it without deleting).")
        var archive: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.updateMemory(query: arguments.memoryQuery, id: nil, newTitle: arguments.newTitle, newContent: arguments.newContent, newCategory: nil, archive: arguments.archive ? true : nil)
    }
}

@available(iOS 26.0, *)
struct DeleteMemoryTool: Tool {
    let name = "deleteMemory"
    let description = "Delete one memory, or request deletion of all memories (the app asks the user to confirm bulk deletion)."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Words identifying which memory, or 'that'. Ignored when deleteAll is true.")
        var memoryQuery: String
        @Guide(description: "true only if the user explicitly asked to delete ALL memories.")
        var deleteAll: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.deleteMemory(query: arguments.memoryQuery, id: nil, deleteAll: arguments.deleteAll)
    }
}

@available(iOS 26.0, *)
struct SearchMemoriesTool: Tool {
    let name = "searchMemories"
    let description = "Find what the user previously asked DayMind to remember, e.g. 'what did I tell you about Michael'."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Search words, e.g. 'Michael' or 'kitchen countertop'.")
        var query: String
        @Guide(description: "Restrict to memories about this person, or empty string.")
        var personName: String
        @Guide(description: "Restrict to this project, or empty string.")
        var projectName: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.searchMemories(query: arguments.query, personName: arguments.personName, projectName: arguments.projectName)
    }
}

@available(iOS 26.0, *)
struct CreateProjectTool: Tool {
    let name = "createProject"
    let description = "Create a project to group related reminders and memories, e.g. 'kitchen renovation'."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Project name")
        var name: String
        @Guide(description: "One-sentence summary or empty string")
        var summary: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.createProject(name: arguments.name, summary: arguments.summary)
    }
}

@available(iOS 26.0, *)
struct AssociateItemWithProjectTool: Tool {
    let name = "associateItemWithProject"
    let description = "File a reminder or memory under a project, e.g. 'save this under the kitchen renovation project'."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Project name")
        var projectName: String
        @Guide(description: "What to file: 'lastSaved' for 'this'/'that', otherwise 'reminder' or 'memory'.", .anyOf(["lastSaved", "reminder", "memory"]))
        var itemKind: String
        @Guide(description: "Words identifying the item, or empty string for the most recent item.")
        var itemQuery: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.associateItemWithProject(projectName: arguments.projectName, itemKind: arguments.itemKind, itemQuery: arguments.itemQuery)
    }
}

@available(iOS 26.0, *)
struct GetDailyBriefingTool: Tool {
    let name = "getDailyBriefing"
    let description = "Get today's briefing: today's reminders, overdue items, important upcoming items and inbox count."
    let actions: AssistantActions

    @Generable
    struct Arguments {
        @Guide(description: "Always 'today'.")
        var day: String
    }

    func call(arguments: Arguments) async throws -> String {
        await actions.dailyBriefing()
    }
}

@available(iOS 26.0, *)
enum ToolCatalog {
    static func all(_ actions: AssistantActions) -> [any Tool] {
        [CreateReminderTool(actions: actions), UpdateReminderTool(actions: actions), CompleteReminderTool(actions: actions),
         DeleteReminderTool(actions: actions), SnoozeReminderTool(actions: actions), ListRemindersTool(actions: actions),
         SaveMemoryTool(actions: actions), UpdateMemoryTool(actions: actions), DeleteMemoryTool(actions: actions),
         SearchMemoriesTool(actions: actions), CreateProjectTool(actions: actions), AssociateItemWithProjectTool(actions: actions),
         GetDailyBriefingTool(actions: actions)]
    }

    /// Smaller tool sets per intent keep the schema the 3-billion-parameter model sees short.
    static func tools(for intent: IntentKind, actions: AssistantActions) -> [any Tool] {
        switch intent {
        case .createReminder:
            return [CreateReminderTool(actions: actions), SaveMemoryTool(actions: actions)]
        case .modifyReminder:
            return [UpdateReminderTool(actions: actions), CompleteReminderTool(actions: actions), DeleteReminderTool(actions: actions),
                    SnoozeReminderTool(actions: actions), ListRemindersTool(actions: actions)]
        case .queryReminders:
            return [ListRemindersTool(actions: actions), GetDailyBriefingTool(actions: actions)]
        case .saveMemory:
            return [SaveMemoryTool(actions: actions), CreateReminderTool(actions: actions), AssociateItemWithProjectTool(actions: actions)]
        case .queryMemories:
            return [SearchMemoriesTool(actions: actions), UpdateMemoryTool(actions: actions), DeleteMemoryTool(actions: actions)]
        case .projectAction:
            return [CreateProjectTool(actions: actions), AssociateItemWithProjectTool(actions: actions), SearchMemoriesTool(actions: actions)]
        case .dailyBriefing:
            return [GetDailyBriefingTool(actions: actions)]
        case .mixed:
            return all(actions)
        case .conversation:
            return [SearchMemoriesTool(actions: actions), ListRemindersTool(actions: actions)]
        }
    }
}
#endif

/// Coarse intent used to pick a tool group. Kept outside the `#if` so the engine can reason about it
/// even on builds without Foundation Models.
enum IntentKind: String, CaseIterable, Sendable {
    case createReminder, modifyReminder, queryReminders, saveMemory, queryMemories, projectAction, dailyBriefing, mixed, conversation
}
