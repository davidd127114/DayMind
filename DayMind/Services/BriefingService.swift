import Foundation
import DayMindCore

/// Builds the daily briefing from the database (no AI needed) and keeps the daily notification scheduled.
@MainActor
final class BriefingService {
    private let reminders: ReminderService
    private let inbox: InboxService
    private let memories: MemoryService
    private let settings: SettingsStore
    private let notifications: NotificationScheduling
    var now: () -> Date = { Date() }

    init(reminders: ReminderService, inbox: InboxService, memories: MemoryService, settings: SettingsStore, notifications: NotificationScheduling) {
        self.reminders = reminders
        self.inbox = inbox
        self.memories = memories
        self.settings = settings
        self.notifications = notifications
    }

    func input() -> BriefingInput {
        let current = now()
        func items(_ list: [Reminder]) -> [BriefingItem] { list.map { BriefingItem(title: $0.title, dueDate: $0.dueDate, priority: $0.priority) } }
        let projectNotes = memories.fetchAll().filter { $0.project != nil && $0.importance == .high }.prefix(1).map { "\($0.project?.name ?? ""): \($0.title)" }
        return BriefingInput(now: current,
                             today: items(reminders.dueToday(asOf: current)),
                             overdue: items(reminders.overdue(asOf: current)),
                             upcoming: items(reminders.upcoming(days: 7, asOf: current)),
                             inboxCount: inbox.unresolvedCount,
                             projectNotes: Array(projectNotes))
    }

    func composeText() -> String {
        BriefingComposer(calendar: settings.calendar).compose(input())
    }

    func headline() -> String {
        BriefingComposer(calendar: settings.calendar).headline(input())
    }

    /// Re-schedules the repeating briefing notification with a fresh body. The body reflects the
    /// data at scheduling time; it is refreshed every time the app launches or returns to the foreground.
    func refreshSchedule() async {
        guard settings.briefingEnabled else {
            await notifications.cancelBriefing()
            return
        }
        await notifications.scheduleBriefing(at: settings.briefingTime, title: "Your DayMind briefing", body: composeText())
    }
}
