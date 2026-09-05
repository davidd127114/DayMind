import Foundation
import UserNotifications
import os
import DayMindCore

/// Everything needed to (re)create one notification request. Computed on the main actor from a
/// `Reminder`, then handed to the scheduler, which never touches SwiftData.
struct NotificationPlan: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    /// One-shot fire date (used when `repeating` is nil).
    var fireDate: Date?
    /// Repeating calendar components for simple rules ("every Monday at 9").
    var repeating: DateComponents?
    var reminderID: UUID
    var isFollowUp: Bool = false
}

enum NotificationCategory {
    static let reminder = "DAYMIND_REMINDER"
    static let briefing = "DAYMIND_BRIEFING"
    static let actionComplete = "COMPLETE"
    static let actionSnoozeHour = "SNOOZE_1H"
    static let actionOpen = "OPEN"
    static let briefingIdentifier = "daymind-daily-briefing"
    static let reminderIDKey = "reminderID"
}

/// Abstracted so unit tests can verify scheduling without the real notification center.
protocol NotificationScheduling: AnyObject, Sendable {
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Schedules the plans. Returns a description of the failure for each identifier that could NOT be scheduled.
    @discardableResult
    func apply(plans: [NotificationPlan]) async -> [String: String]
    func remove(identifiers: [String]) async
    /// Fires a one-off "notifications are working" alert a few seconds from now (onboarding test).
    func scheduleTestNotification(after seconds: TimeInterval) async -> String?
    func pendingReminderIdentifiers() async -> Set<String>
    func scheduleBriefing(at time: TimeOfDay, title: String, body: String) async
    func cancelBriefing() async
    func removeAll() async
}

/// Production implementation over `UNUserNotificationCenter`.
final class LocalNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "Notifications")

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        registerCategories()
    }

    private func registerCategories() {
        let complete = UNNotificationAction(identifier: NotificationCategory.actionComplete, title: "Complete", options: [])
        let snooze = UNNotificationAction(identifier: NotificationCategory.actionSnoozeHour, title: "Snooze 1 hour", options: [])
        let open = UNNotificationAction(identifier: NotificationCategory.actionOpen, title: "Open in DayMind", options: [.foreground])
        let reminder = UNNotificationCategory(identifier: NotificationCategory.reminder, actions: [complete, snooze, open], intentIdentifiers: [], options: [])
        let briefing = UNNotificationCategory(identifier: NotificationCategory.briefing, actions: [open], intentIdentifiers: [], options: [])
        center.setNotificationCategories([reminder, briefing])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func apply(plans: [NotificationPlan]) async -> [String: String] {
        var failures: [String: String] = [:]
        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.reminder
            content.threadIdentifier = "reminders"
            content.userInfo = [NotificationCategory.reminderIDKey: plan.reminderID.uuidString]

            let trigger: UNNotificationTrigger
            if let repeating = plan.repeating {
                trigger = UNCalendarNotificationTrigger(dateMatching: repeating, repeats: true)
            } else if let fireDate = plan.fireDate {
                guard fireDate > Date() else {
                    // Already in the past: nothing to schedule, but make sure stale requests are gone.
                    center.removePendingNotificationRequests(withIdentifiers: [plan.identifier])
                    continue
                }
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
                trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [plan.identifier])
                continue
            }
            let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                logger.error("Could not schedule \(plan.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures[plan.identifier] = error.localizedDescription
            }
        }
        return failures
    }

    func scheduleTestNotification(after seconds: TimeInterval) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = "DayMind"
        content.body = "Notifications are working. This is how a reminder will look."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: "daymind-test-notification", content: content, trigger: trigger)
        do { try await center.add(request); return nil } catch { return error.localizedDescription }
    }

    func remove(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func pendingReminderIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter { $0.hasPrefix("reminder-") })
    }

    func scheduleBriefing(at time: TimeOfDay, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.briefing
        var comps = DateComponents()
        comps.hour = time.hour
        comps.minute = time.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: NotificationCategory.briefingIdentifier, content: content, trigger: trigger)
        do { try await center.add(request) } catch {
            logger.error("Could not schedule briefing: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelBriefing() async {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationCategory.briefingIdentifier])
    }

    func removeAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// Builds notification plans from reminders. Pure, so it is unit-tested directly.
enum NotificationPlanner {
    static func plans(for reminder: Reminder, calendar: Calendar, now: Date = Date()) -> [NotificationPlan] {
        guard reminder.isPending, let dueDate = reminder.dueDate else { return [] }
        var plans: [NotificationPlan] = []
        let body = reminder.notes.isEmpty ? "Tap to open in DayMind." : reminder.notes
        var main = NotificationPlan(identifier: reminder.notificationRequestIdentifier, title: reminder.title, body: body, fireDate: nil, repeating: nil, reminderID: reminder.id)

        if let rule = reminder.recurrence {
            if let comps = rule.repeatingTriggerComponents(anchor: dueDate, calendar: calendar) {
                main.repeating = comps
            } else {
                // Complex rule: schedule the next single occurrence; the app reschedules on launch/completion.
                let next = dueDate > now ? dueDate : rule.nextOccurrence(after: now, anchor: dueDate, calendar: calendar)
                main.fireDate = next
            }
        } else {
            main.fireDate = dueDate
        }
        if main.fireDate != nil || main.repeating != nil { plans.append(main) }

        if let followUp = reminder.followUpDate, followUp > now {
            plans.append(NotificationPlan(identifier: reminder.followUpNotificationIdentifier, title: "Still to do: \(reminder.title)",
                                          body: "You asked to be reminded again.", fireDate: followUp, repeating: nil, reminderID: reminder.id, isFollowUp: true))
        }
        return plans
    }

    static func identifiers(for reminder: Reminder) -> [String] {
        [reminder.notificationRequestIdentifier, reminder.followUpNotificationIdentifier]
    }
}
