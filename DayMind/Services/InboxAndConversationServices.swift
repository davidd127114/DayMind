import Foundation
import SwiftData
import DayMindCore

/// The Unprocessed Inbox: nothing the user says is ever lost.
@MainActor
final class InboxService {
    private let store: DataStore
    init(store: DataStore) { self.store = store }

    @discardableResult
    func add(text: String, source: CaptureSource, reason: InboxReason, detail: String? = nil) -> InboxItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = InboxItem(text: trimmed, source: source, reason: reason, detail: detail)
        store.context.insert(item)
        try? store.save()
        return item
    }

    func unresolved() -> [InboxItem] {
        let d = FetchDescriptor<InboxItem>(predicate: #Predicate { !$0.isResolved }, sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        return (try? store.context.fetch(d)) ?? []
    }

    func all() -> [InboxItem] {
        let d = FetchDescriptor<InboxItem>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        return (try? store.context.fetch(d)) ?? []
    }

    func fetch(id: UUID) -> InboxItem? {
        var d = FetchDescriptor<InboxItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? store.context.fetch(d).first
    }

    func markResolved(_ item: InboxItem) {
        item.isResolved = true
        try? store.save()
    }

    func recordRetry(_ item: InboxItem, reason: InboxReason, detail: String?) {
        item.retryCount += 1
        item.reason = reason
        item.detail = detail
        try? store.save()
    }

    func delete(_ item: InboxItem) {
        store.context.delete(item)
        try? store.save()
    }

    var unresolvedCount: Int { unresolved().count }
}

/// Conversation history shown on the Talk screen. Subject to the transcript-retention setting.
@MainActor
final class ConversationService {
    private let store: DataStore
    private let settings: SettingsStore

    init(store: DataStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    @discardableResult
    func append(role: ConversationRole, text: String, actionSummary: String? = nil) -> ConversationTurn? {
        guard settings.transcriptRetention != .never else { return nil }
        let turn = ConversationTurn(role: role, text: text, actionSummary: actionSummary)
        store.context.insert(turn)
        try? store.save()
        return turn
    }

    func recent(limit: Int = 40) -> [ConversationTurn] {
        var d = FetchDescriptor<ConversationTurn>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = limit
        return ((try? store.context.fetch(d)) ?? []).reversed()
    }

    func clear() {
        try? store.context.delete(model: ConversationTurn.self)
        try? store.save()
    }

    /// Applies the retention policy to conversation turns and to the raw transcripts stored on
    /// reminders and memories.
    func purgeExpired(now: Date = Date()) {
        let retention = settings.transcriptRetention
        switch retention.retentionDays {
        case nil:
            return
        case 0?:
            clear()
            stripTranscripts(olderThan: now)
        case let days?:
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let d = FetchDescriptor<ConversationTurn>(predicate: #Predicate { $0.timestamp < cutoff })
            for turn in (try? store.context.fetch(d)) ?? [] { store.context.delete(turn) }
            stripTranscripts(olderThan: cutoff)
            try? store.save()
        }
    }

    private func stripTranscripts(olderThan cutoff: Date) {
        let reminders = (try? store.context.fetch(FetchDescriptor<Reminder>())) ?? []
        for r in reminders where r.originalTranscript != nil && r.createdAt < cutoff { r.originalTranscript = nil }
        let memories = (try? store.context.fetch(FetchDescriptor<Memory>())) ?? []
        for m in memories where m.originalTranscript != nil && m.createdAt < cutoff { m.originalTranscript = nil }
        try? store.save()
    }
}
