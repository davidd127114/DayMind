import Foundation
import SwiftData
import DayMindCore

enum ReminderServiceError: LocalizedError, Equatable {
    case emptyTitle
    case titleTooLong
    case dateTooFar
    case recurrenceNeedsDate
    case notFound
    case possibleDuplicate(existingID: UUID, existingTitle: String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "The reminder needs a title."
        case .titleTooLong: return "That title is too long (200 characters max)."
        case .dateTooFar: return "That date is more than ten years away. Please pick a closer date."
        case .recurrenceNeedsDate: return "A repeating reminder needs a first date and time."
        case .notFound: return "I couldn't find that reminder."
        case .possibleDuplicate(_, let title): return "You already have a similar reminder: “\(title)”."
        }
    }
}

struct ReminderChanges: Equatable, Sendable {
    var title: String?
    var notes: String?
    var dueDate: Date??
    var recurrence: RecurrenceRule??
    var priority: ReminderPriority?
    var people: [String]?
    var projectName: String??

    init(title: String? = nil, notes: String? = nil, dueDate: Date?? = nil, recurrence: RecurrenceRule?? = nil, priority: ReminderPriority? = nil, people: [String]? = nil, projectName: String?? = nil) {
        self.title = title; self.notes = notes; self.dueDate = dueDate; self.recurrence = recurrence; self.priority = priority; self.people = people; self.projectName = projectName
    }
}

/// All reminder mutations go through here so notifications stay in sync with the database.
@MainActor
final class ReminderService {
    private let store: DataStore
    private let notifications: NotificationScheduling
    private let settings: SettingsStore
    private let people: PersonService
    private let projects: ProjectService
    var now: () -> Date = { Date() }

    init(store: DataStore, notifications: NotificationScheduling, settings: SettingsStore, people: PersonService, projects: ProjectService) {
        self.store = store
        self.notifications = notifications
        self.settings = settings
        self.people = people
        self.projects = projects
    }

    private var context: ModelContext { store.context }
    private var calendar: Calendar { settings.calendar }

    // MARK: Create

    @discardableResult
    func create(from draft: ReminderDraft, transcript: String?, allowDuplicate: Bool = false) async throws -> Reminder {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(title: title, dueDate: draft.dueDate, recurrence: draft.recurrence, now: now())
        if !allowDuplicate, let dup = findDuplicate(title: title, dueDate: draft.dueDate) {
            throw ReminderServiceError.possibleDuplicate(existingID: dup.id, existingTitle: dup.title)
        }
        let reminder = Reminder(title: title, notes: draft.notes, dueDate: draft.dueDate, timeZoneIdentifier: settings.timeZone.identifier,
                                recurrence: draft.recurrence, priority: draft.priority, originalTranscript: keepTranscript(transcript))
        reminder.people = draft.people.map { people.findOrCreate(name: $0) }
        if let name = draft.projectName, !name.isEmpty { reminder.project = projects.findOrCreate(name: name) }
        context.insert(reminder)
        try store.save()
        await syncNotifications(for: reminder)
        return reminder
    }

    static func validate(title: String, dueDate: Date?, recurrence: RecurrenceRule?, now: Date) throws {
        guard !title.isEmpty else { throw ReminderServiceError.emptyTitle }
        guard title.count <= 200 else { throw ReminderServiceError.titleTooLong }
        if let dueDate, dueDate > now.addingTimeInterval(10 * 366 * 86_400) { throw ReminderServiceError.dateTooFar }
        if recurrence != nil, dueDate == nil { throw ReminderServiceError.recurrenceNeedsDate }
    }

    func findDuplicate(title: String, dueDate: Date?) -> Reminder? {
        for candidate in pending() where TextMatching.score(query: title, against: candidate.title) >= 0.85 {
            switch (dueDate, candidate.dueDate) {
            case (nil, nil): return candidate
            case (let a?, let b?) where calendar.isDate(a, inSameDayAs: b): return candidate
            default: continue
            }
        }
        return nil
    }

    // MARK: Update

    func apply(_ changes: ReminderChanges, to reminder: Reminder) async throws {
        if let title = changes.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(title: trimmed, dueDate: reminder.dueDate, recurrence: reminder.recurrence, now: now())
            reminder.title = trimmed
        }
        if let notes = changes.notes { reminder.notes = notes }
        if let due = changes.dueDate {
            try Self.validate(title: reminder.title, dueDate: due, recurrence: reminder.recurrence, now: now())
            reminder.dueDate = due
        }
        if let rec = changes.recurrence {
            try Self.validate(title: reminder.title, dueDate: reminder.dueDate, recurrence: rec, now: now())
            reminder.recurrence = rec
        }
        if let priority = changes.priority { reminder.priority = priority }
        if let names = changes.people { reminder.people = names.map { people.findOrCreate(name: $0) } }
        if let project = changes.projectName {
            reminder.project = project.flatMap { $0.isEmpty ? nil : projects.findOrCreate(name: $0) }
        }
        reminder.touch()
        try store.save()
        await syncNotifications(for: reminder)
    }

    func reschedule(_ reminder: Reminder, to date: Date) async throws {
        try await apply(ReminderChanges(dueDate: .some(date)), to: reminder)
    }

    func snooze(_ reminder: Reminder, by interval: TimeInterval) async throws -> Date {
        let base = max(now(), reminder.dueDate ?? now())
        let newDate = base.addingTimeInterval(interval)
        var history = reminder.snoozeHistory
        history.append(SnoozeEvent(snoozedAt: now(), previousDueDate: reminder.dueDate, newDueDate: newDate))
        reminder.snoozeHistory = history
        reminder.dueDate = newDate
        reminder.status = .pending
        reminder.touch()
        try store.save()
        await syncNotifications(for: reminder)
        return newDate
    }

    func setFollowUp(_ reminder: Reminder, at date: Date?) async throws {
        reminder.followUpDate = date
        reminder.touch()
        try store.save()
        await syncNotifications(for: reminder)
    }

    /// Completes a reminder. Recurring reminders roll to their next occurrence instead of closing.
    /// Returns the next occurrence for recurring reminders.
    @discardableResult
    func complete(_ reminder: Reminder) async throws -> Date? {
        let current = now()
        if let rule = reminder.recurrence, let due = reminder.dueDate {
            let next = rule.nextOccurrence(after: max(current, due), anchor: due, calendar: calendar)
            reminder.followUpDate = nil
            if let next {
                reminder.dueDate = next
                reminder.status = .pending
                reminder.completedAt = current
                reminder.touch()
                try store.save()
                await syncNotifications(for: reminder)
                return next
            }
        }
        reminder.status = .completed
        reminder.completedAt = current
        reminder.followUpDate = nil
        reminder.touch()
        try store.save()
        await notifications.remove(identifiers: NotificationPlanner.identifiers(for: reminder))
        return nil
    }

    func reopen(_ reminder: Reminder) async throws {
        reminder.status = .pending
        reminder.completedAt = nil
        reminder.touch()
        try store.save()
        await syncNotifications(for: reminder)
    }

    func delete(_ reminder: Reminder) async throws {
        let ids = NotificationPlanner.identifiers(for: reminder)
        context.delete(reminder)
        try store.save()
        await notifications.remove(identifiers: ids)
    }

    func deleteAll() async throws -> Int {
        let all = fetchAll()
        let ids = all.flatMap { NotificationPlanner.identifiers(for: $0) }
        for r in all { context.delete(r) }
        try store.save()
        await notifications.remove(identifiers: ids)
        return all.count
    }

    // MARK: Queries

    func fetchAll() -> [Reminder] {
        let descriptor = FetchDescriptor<Reminder>(sortBy: [SortDescriptor(\.dueDate, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetch(id: UUID) -> Reminder? {
        var d = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func pending() -> [Reminder] {
        let pendingRaw = ReminderStatus.pending.rawValue
        let d = FetchDescriptor<Reminder>(predicate: #Predicate { $0.statusRaw == pendingRaw }, sortBy: [SortDescriptor(\.dueDate, order: .forward)])
        return (try? context.fetch(d)) ?? []
    }

    func completed(limit: Int = 50) -> [Reminder] {
        let raw = ReminderStatus.completed.rawValue
        var d = FetchDescriptor<Reminder>(predicate: #Predicate { $0.statusRaw == raw }, sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    func overdue(asOf date: Date? = nil) -> [Reminder] {
        let ref = date ?? now()
        return pending().filter { ($0.dueDate ?? .distantFuture) < ref }
    }

    func dueToday(asOf date: Date? = nil) -> [Reminder] {
        let ref = date ?? now()
        return pending().filter { r in
            guard let due = r.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: ref) && due >= ref
        }
    }

    func dueOn(day: Date) -> [Reminder] {
        pending().filter { r in
            guard let due = r.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
    }

    func upcoming(days: Int = 7, asOf date: Date? = nil) -> [Reminder] {
        let ref = date ?? now()
        let endOfToday = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: ref) ?? ref
        let horizon = calendar.date(byAdding: .day, value: days, to: ref) ?? ref
        return pending().filter { r in
            guard let due = r.dueDate else { return false }
            return due > endOfToday && due <= horizon
        }
    }

    func undated() -> [Reminder] { pending().filter { $0.dueDate == nil } }

    /// Reminders that were due on `day` and were not completed by the end of that day, plus missed
    /// recurring occurrences recorded for that day.
    func forgotten(on day: Date) -> [Reminder] {
        fetchAll().filter { r in
            if r.isPending, let due = r.dueDate, calendar.isDate(due, inSameDayAs: day), due < now() { return true }
            if r.missedOccurrences.contains(where: { calendar.isDate($0.dueDate, inSameDayAs: day) }) { return true }
            if r.status == .completed, let due = r.dueDate, let done = r.completedAt, calendar.isDate(due, inSameDayAs: day),
               let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day), done > endOfDay { return true }
            return false
        }
    }

    func list(scope: ReminderListScope) -> [Reminder] {
        let current = now()
        switch scope {
        case .today: return (overdue(asOf: current) + dueToday(asOf: current)).sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
        case .overdue: return overdue(asOf: current)
        case .upcoming: return upcoming(asOf: current)
        case .tomorrow:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: current) else { return [] }
            return dueOn(day: tomorrow)
        case .thisWeek:
            let end = calendar.dateInterval(of: .weekOfYear, for: current)?.end ?? current
            return pending().filter { ($0.dueDate ?? .distantFuture) <= end }
        case .forgottenYesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: current) else { return [] }
            return forgotten(on: yesterday)
        case .all: return pending()
        }
    }

    /// Finds the reminder(s) the user is referring to. Empty = none; more than one = ambiguous.
    func find(reference: ReminderReference, focusID: UUID?) -> [Reminder] {
        if reference.usesAnaphora, let focusID, let focused = fetch(id: focusID) { return [focused] }
        var candidates = pending()
        if let day = reference.dayHint {
            let sameDay = candidates.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
            if !sameDay.isEmpty { candidates = sameDay }
        }
        guard let hint = reference.titleHint, !hint.isEmpty else {
            if reference.dayHint != nil { return candidates }
            if reference.usesAnaphora, let focusID, let focused = fetch(id: focusID) { return [focused] }
            return []
        }
        let ranked = TextMatching.rank(candidates, query: hint, text: { "\($0.title) \($0.notes) \($0.peopleNames.joined(separator: " "))" }, threshold: 0.5)
        guard let best = ranked.first else { return [] }
        // Keep everything that ties with the best match; drop clearly weaker ones.
        return ranked.filter { $0.score >= best.score - 0.15 }.map(\.item)
    }

    func find(titleQuery: String) -> [Reminder] {
        find(reference: ReminderReference(titleHint: titleQuery), focusID: nil)
    }

    // MARK: Maintenance

    /// Recurring reminders whose occurrence passed without completion: record the miss and move
    /// to the next occurrence so Today shows the right one. Called at launch and on foreground.
    func rollForwardRecurring() async {
        let current = now()
        var changed = false
        for r in pending() {
            guard let rule = r.recurrence, var due = r.dueDate else { continue }
            var missed = r.missedOccurrences
            var guardCount = 0
            while let next = rule.nextOccurrence(after: due, anchor: due, calendar: calendar), next <= current, guardCount < 1000 {
                missed.append(MissedOccurrence(dueDate: due, recordedAt: current))
                due = next
                guardCount += 1
            }
            if guardCount > 0 {
                r.missedOccurrences = Array(missed.suffix(100))
                r.dueDate = due
                r.touch()
                changed = true
            }
        }
        if changed {
            try? store.save()
            await reconcileNotifications()
        }
    }

    /// Ensures every pending reminder has its notification and no orphaned requests remain.
    func reconcileNotifications() async {
        let pendingIDs = await notifications.pendingReminderIdentifiers()
        var desired: [NotificationPlan] = []
        var expected = Set<String>()
        for r in pending() {
            let plans = NotificationPlanner.plans(for: r, calendar: calendar, now: now())
            for p in plans {
                expected.insert(p.identifier)
                if !pendingIDs.contains(p.identifier) || p.repeating == nil { desired.append(p) }
            }
            if r.notificationIdentifier != r.notificationRequestIdentifier {
                r.notificationIdentifier = r.notificationRequestIdentifier
            }
        }
        try? store.save()
        await notifications.apply(plans: desired)
        let orphans = pendingIDs.subtracting(expected)
        await notifications.remove(identifiers: Array(orphans))
    }

    private func syncNotifications(for reminder: Reminder) async {
        let plans = NotificationPlanner.plans(for: reminder, calendar: calendar, now: now())
        let planned = Set(plans.map(\.identifier))
        let stale = NotificationPlanner.identifiers(for: reminder).filter { !planned.contains($0) }
        await notifications.remove(identifiers: stale)
        await notifications.apply(plans: plans)
        reminder.notificationIdentifier = plans.isEmpty ? nil : reminder.notificationRequestIdentifier
        try? store.save()
    }

    private func keepTranscript(_ transcript: String?) -> String? {
        guard settings.transcriptRetention != .never else { return nil }
        return transcript
    }

    func summary(_ reminder: Reminder) -> ReminderSummary { ReminderSummary(reminder, calendar: calendar) }
}
