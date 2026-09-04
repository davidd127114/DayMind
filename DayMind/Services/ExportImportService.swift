import Foundation
import SwiftData
import DayMindCore

/// JSON backup and restore. Import merges by UUID (newer `lastModified` wins) so it is safe to
/// restore into a store that already has data.
@MainActor
final class ExportImportService {
    private let store: DataStore
    private let settings: SettingsStore
    private let reminders: ReminderService

    init(store: DataStore, settings: SettingsStore, reminders: ReminderService) {
        self.store = store
        self.settings = settings
        self.reminders = reminders
    }

    private var context: ModelContext { store.context }

    func exportDocument() throws -> ExportDocument {
        let rs = try context.fetch(FetchDescriptor<Reminder>())
        let ms = try context.fetch(FetchDescriptor<Memory>())
        let ps = try context.fetch(FetchDescriptor<Person>())
        let pjs = try context.fetch(FetchDescriptor<Project>())
        let ib = try context.fetch(FetchDescriptor<InboxItem>())
        let cs = try context.fetch(FetchDescriptor<ConversationTurn>())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ExportDocument(
            exportedAt: Date(), appVersion: version,
            reminders: rs.map { r in
                ReminderDTO(id: r.id, title: r.title, notes: r.notes, createdAt: r.createdAt, dueDate: r.dueDate, timeZoneIdentifier: r.timeZoneIdentifier,
                            recurrence: r.recurrence, priority: r.priority, status: r.status, completedAt: r.completedAt, snoozeHistory: r.snoozeHistory,
                            missedOccurrences: r.missedOccurrences, notificationIdentifier: r.notificationIdentifier, peopleIDs: (r.people ?? []).map(\.id),
                            projectID: r.project?.id, relatedMemoryIDs: r.relatedMemoryIDs, originalTranscript: r.originalTranscript, lastModified: r.lastModified,
                            repeatIfIncomplete: r.followUpDate != nil)
            },
            memories: ms.map { m in
                MemoryDTO(id: m.id, title: m.title, content: m.content, category: m.category, peopleIDs: (m.people ?? []).map(\.id), projectID: m.project?.id,
                          tags: m.tags, importance: m.importance, createdAt: m.createdAt, lastAccessedAt: m.lastAccessedAt, originalTranscript: m.originalTranscript,
                          isArchived: m.isArchived, lastModified: m.lastModified)
            },
            people: ps.map { PersonDTO(id: $0.id, name: $0.name, notes: $0.notes, createdAt: $0.createdAt) },
            projects: pjs.map { ProjectDTO(id: $0.id, name: $0.name, summary: $0.summary, colorName: $0.colorName, createdAt: $0.createdAt, isArchived: $0.isArchived) },
            inbox: ib.map { InboxItemDTO(id: $0.id, text: $0.text, capturedAt: $0.capturedAt, source: $0.source, reason: $0.reason, detail: $0.detail, retryCount: $0.retryCount) },
            conversation: cs.map { ConversationTurnDTO(id: $0.id, role: $0.role, text: $0.text, timestamp: $0.timestamp, actionSummary: $0.actionSummary) },
            preferences: PreferencesDTO(timeZoneIdentifier: settings.timeZoneIdentifier, timeDefaults: settings.timeDefaults, briefingEnabled: settings.briefingEnabled,
                                        briefingTime: settings.briefingTime, transcriptRetention: settings.transcriptRetention, voiceIdentifier: settings.voiceIdentifier,
                                        speechRate: settings.speechRate)
        )
    }

    /// Writes the backup to a temporary file and returns its URL (for the share sheet).
    func exportToTemporaryFile() throws -> URL {
        let doc = try exportDocument()
        let data = try doc.encoded()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayMind-backup-\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    struct ImportSummary: Equatable {
        var reminders = 0, memories = 0, people = 0, projects = 0, inbox = 0
        var description: String { "Imported \(reminders) reminders, \(memories) memories, \(people) people, \(projects) projects and \(inbox) inbox items." }
    }

    @discardableResult
    func importData(_ data: Data, applyPreferences: Bool = true) async throws -> ImportSummary {
        let doc = try ExportDocument.decode(data)
        var summary = ImportSummary()

        var peopleByID: [UUID: Person] = [:]
        let existingPeople = try context.fetch(FetchDescriptor<Person>())
        for dto in doc.people {
            if let existing = existingPeople.first(where: { $0.id == dto.id }) ?? existingPeople.first(where: { $0.name.localizedCaseInsensitiveCompare(dto.name) == .orderedSame }) {
                peopleByID[dto.id] = existing
            } else {
                let p = Person(name: dto.name, notes: dto.notes)
                p.id = dto.id
                p.createdAt = dto.createdAt
                context.insert(p)
                peopleByID[dto.id] = p
                summary.people += 1
            }
        }

        var projectsByID: [UUID: Project] = [:]
        let existingProjects = try context.fetch(FetchDescriptor<Project>())
        for dto in doc.projects {
            if let existing = existingProjects.first(where: { $0.id == dto.id }) ?? existingProjects.first(where: { $0.name.localizedCaseInsensitiveCompare(dto.name) == .orderedSame }) {
                projectsByID[dto.id] = existing
            } else {
                let p = Project(name: dto.name, summary: dto.summary, colorName: dto.colorName)
                p.id = dto.id
                p.createdAt = dto.createdAt
                p.isArchived = dto.isArchived
                context.insert(p)
                projectsByID[dto.id] = p
                summary.projects += 1
            }
        }

        let existingReminders = try context.fetch(FetchDescriptor<Reminder>())
        for dto in doc.reminders {
            let target: Reminder
            if let existing = existingReminders.first(where: { $0.id == dto.id }) {
                guard dto.lastModified > existing.lastModified else { continue }
                target = existing
            } else {
                target = Reminder(title: dto.title)
                target.id = dto.id
                target.createdAt = dto.createdAt
                context.insert(target)
                summary.reminders += 1
            }
            target.title = dto.title
            target.notes = dto.notes
            target.dueDate = dto.dueDate
            target.timeZoneIdentifier = dto.timeZoneIdentifier
            target.recurrence = dto.recurrence
            target.priority = dto.priority
            target.status = dto.status
            target.completedAt = dto.completedAt
            target.snoozeHistory = dto.snoozeHistory
            target.missedOccurrences = dto.missedOccurrences
            target.relatedMemoryIDs = dto.relatedMemoryIDs
            target.originalTranscript = dto.originalTranscript
            target.lastModified = dto.lastModified
            target.people = dto.peopleIDs.compactMap { peopleByID[$0] }
            target.project = dto.projectID.flatMap { projectsByID[$0] }
        }

        let existingMemories = try context.fetch(FetchDescriptor<Memory>())
        for dto in doc.memories {
            let target: Memory
            if let existing = existingMemories.first(where: { $0.id == dto.id }) {
                guard dto.lastModified > existing.lastModified else { continue }
                target = existing
            } else {
                target = Memory(title: dto.title, content: dto.content)
                target.id = dto.id
                target.createdAt = dto.createdAt
                context.insert(target)
                summary.memories += 1
            }
            target.title = dto.title
            target.content = dto.content
            target.category = dto.category
            target.tags = dto.tags
            target.importance = dto.importance
            target.lastAccessedAt = dto.lastAccessedAt
            target.originalTranscript = dto.originalTranscript
            target.isArchived = dto.isArchived
            target.lastModified = dto.lastModified
            target.people = dto.peopleIDs.compactMap { peopleByID[$0] }
            target.project = dto.projectID.flatMap { projectsByID[$0] }
        }

        let existingInbox = try context.fetch(FetchDescriptor<InboxItem>())
        for dto in doc.inbox where !existingInbox.contains(where: { $0.id == dto.id }) {
            let item = InboxItem(text: dto.text, source: dto.source, reason: dto.reason, detail: dto.detail)
            item.id = dto.id
            item.capturedAt = dto.capturedAt
            item.retryCount = dto.retryCount
            context.insert(item)
            summary.inbox += 1
        }

        if applyPreferences, let prefs = doc.preferences {
            settings.timeZoneIdentifier = prefs.timeZoneIdentifier
            settings.timeDefaults = prefs.timeDefaults
            settings.briefingEnabled = prefs.briefingEnabled
            settings.briefingTime = prefs.briefingTime
            settings.transcriptRetention = prefs.transcriptRetention
            settings.voiceIdentifier = prefs.voiceIdentifier
            settings.speechRate = prefs.speechRate
        }

        try store.save()
        await reminders.reconcileNotifications()
        return summary
    }
}
