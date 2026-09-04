import Foundation
import DayMindCore

/// Development sample data. Loaded automatically only when the `DAYMIND_SEED_SAMPLE_DATA`
/// environment variable is set (the Xcode scheme sets it) and the store is empty, or on demand
/// from Settings.
@MainActor
enum SampleData {
    static var isRequestedByEnvironment: Bool {
        ProcessInfo.processInfo.environment["DAYMIND_SEED_SAMPLE_DATA"] == "1"
    }

    static func seed(into env: AppEnvironment) async {
        let cal = env.settings.calendar
        let now = Date()
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let kitchen = env.projects.findOrCreate(name: "Kitchen Renovation")
        try? env.projects.update(kitchen, summary: "Replace cabinets, new countertop, move the sink.")
        let michael = env.people.findOrCreate(name: "Michael")
        _ = env.people.findOrCreate(name: "John")

        let drafts: [ReminderDraft] = [
            ReminderDraft(title: "Call Michael", dueDate: at(0, 15), hasExplicitTime: true, people: ["Michael"]),
            ReminderDraft(title: "Plumber visit", notes: "Ask about moving the sink drain.", dueDate: at(1, 10), hasExplicitTime: true, projectName: "Kitchen Renovation"),
            ReminderDraft(title: "Pay rent", dueDate: RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1).nextOccurrence(after: now, anchor: at(0, 9), calendar: cal),
                          hasExplicitTime: true, recurrence: RecurrenceRule(frequency: .monthly, weekdays: [2], weekOfMonth: 1), priority: .high),
            ReminderDraft(title: "Take the trash out", dueDate: RecurrenceRule(frequency: .weekly, weekdays: [2]).nextOccurrence(after: now, anchor: at(0, 8), calendar: cal),
                          hasExplicitTime: true, recurrence: RecurrenceRule(frequency: .weekly, weekdays: [2])),
            ReminderDraft(title: "Renew car registration", dueDate: at(-2, 9), hasExplicitTime: true),
            ReminderDraft(title: "Pick a countertop sample", dueDate: at(4, 18), hasExplicitTime: true, projectName: "Kitchen Renovation"),
        ]
        for d in drafts {
            _ = try? await env.reminders.create(from: d, transcript: nil, allowDuplicate: true)
        }

        let memories: [MemoryDraft] = [
            MemoryDraft(title: "Michael prefers afternoon appointments", content: "Michael prefers afternoon appointments.", category: .preference, people: ["Michael"]),
            MemoryDraft(title: "John prefers text messages", content: "John prefers text messages over calls.", category: .preference, people: ["John"]),
            MemoryDraft(title: "Doctor's office closed on Fridays", content: "My doctor's office is closed on Fridays.", category: .place, tags: ["doctor", "hours"]),
            MemoryDraft(title: "Countertop decision", content: "We decided on quartz for the kitchen countertop, light grey.", category: .decision, projectName: "Kitchen Renovation", importance: .high),
            MemoryDraft(title: "Idea: under-cabinet lighting", content: "Add warm under-cabinet LED strips during the renovation.", category: .idea, projectName: "Kitchen Renovation"),
        ]
        for m in memories { _ = try? env.memories.create(from: m, transcript: nil) }
        _ = michael

        env.inbox.add(text: "Something about the dentist next month, maybe the 14th or the 15th", source: .voice, reason: .ambiguous, detail: "Two possible dates were mentioned.")
        env.settings.hasSeededSampleData = true
    }
}
