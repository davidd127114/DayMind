import SwiftUI
import SwiftData
import DayMindCore

/// One searchable view of everything the butler keeps: reminders (upcoming and completed),
/// memories, and requests that still need attention. People and projects are searchable
/// metadata shown as tags, never a filing step.
struct MyBookView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    @Query(sort: \Reminder.dueDate, order: .forward) private var reminders: [Reminder]
    @Query(sort: \Memory.createdAt, order: .reverse) private var memories: [Memory]
    @Query(filter: #Predicate<InboxItem> { !$0.isResolved }, sort: \InboxItem.capturedAt, order: .reverse) private var inbox: [InboxItem]

    @State private var editingReminder: Reminder?
    @State private var creatingReminder = false
    @State private var creatingMemory = false
    @State private var inboxToReminder: InboxItem?
    @State private var inboxToMemory: InboxItem?
    @State private var retrying: UUID?
    @State private var retryResult: AssistantResult?
    @State private var now = Date()

    private var filter: BookFilter { router.bookFilter }
    private var query: String { router.bookSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            filterChips
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            List {
                if filter == .needsAttention || (filter == .all && !inbox.isEmpty && query.isEmpty) { needsAttentionSection }
                if filter == .all || filter == .upcoming { remindersSection }
                if filter == .completed { completedSection }
                if filter == .all || filter == .memories { memoriesSection }
                if let retryResult {
                    Section("Last retry") {
                        Text(retryResult.responseText).font(.footnote).foregroundStyle(ButlerTheme.inkSecondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(ButlerTheme.ivory)
        .searchable(text: $router.bookSearch, prompt: "Search reminders, notes, people, projects")
        .navigationTitle("My Book")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { creatingReminder = true } label: { Label("New reminder", systemImage: "bell.badge") }
                    Button { creatingMemory = true } label: { Label("New note", systemImage: "book.closed") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add")
            }
        }
        .onAppear { now = Date() }
        .sheet(item: $editingReminder) { r in NavigationStack { ReminderEditorView(mode: .edit(r)) } }
        .sheet(isPresented: $creatingReminder) { NavigationStack { ReminderEditorView(mode: .create(prefill: nil)) } }
        .sheet(isPresented: $creatingMemory) { NavigationStack { MemoryEditorView(mode: .create(prefill: nil)) } }
        .sheet(item: $inboxToReminder) { item in NavigationStack { ReminderEditorView(mode: .create(prefill: prefillReminder(item)), inboxItemToResolve: item) } }
        .sheet(item: $inboxToMemory) { item in NavigationStack { MemoryEditorView(mode: .create(prefill: prefillMemory(item)), inboxItemToResolve: item) } }
        .navigationDestination(for: UUID.self) { id in
            if let m = env.memories.fetch(id: id) { MemoryDetailView(memory: m) } else { Text("Not found") }
        }
    }

    // MARK: Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BookFilter.allCases) { f in
                    Button { router.bookFilter = f } label: {
                        Label {
                            Text(f.title)
                            if f == .needsAttention, !inbox.isEmpty { Text("\(inbox.count)").font(.caption2.weight(.bold)) }
                        } icon: { Image(systemName: f.systemImage) }
                        .font(.subheadline.weight(filter == f ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(filter == f ? ButlerTheme.goldSoft : ButlerTheme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(filter == f ? ButlerTheme.gold : ButlerTheme.goldSoft))
                        .foregroundStyle(ButlerTheme.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                    .accessibilityIdentifier("filter-\(f.rawValue)")
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }

    // MARK: Sections

    private func matches(_ r: Reminder) -> Bool {
        guard !query.isEmpty else { return true }
        let hay = "\(r.title) \(r.notes) \(r.peopleNames.joined(separator: " ")) \(r.project?.name ?? "")"
        return hay.localizedCaseInsensitiveContains(query) || TextMatching.score(query: query, against: hay) >= 0.5
    }

    private var pendingSorted: [Reminder] {
        let pending = reminders.filter { $0.isPending && matches($0) }
        let dated = pending.filter { $0.dueDate != nil }
        let undated = pending.filter { $0.dueDate == nil }
        return dated + undated
    }

    @ViewBuilder
    private var remindersSection: some View {
        let items = pendingSorted
        Section {
            if items.isEmpty {
                Text(query.isEmpty ? "No reminders yet." : "No reminders match “\(query)”.").foregroundStyle(ButlerTheme.inkSecondary)
            }
            ForEach(items) { r in
                ReminderRow(reminder: r, now: now,
                            onComplete: { Task { _ = try? await env.reminders.complete(r) } },
                            onSnooze: { interval in Task { _ = try? await env.reminders.snooze(r, by: interval) } })
                    .contentShape(Rectangle())
                    .onTapGesture { editingReminder = r }
                    .listRowBackground(ButlerTheme.card)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { Task { try? await env.reminders.delete(r) } } label: { Label("Delete", systemImage: "trash") }
                        Button { editingReminder = r } label: { Label("Edit", systemImage: "pencil") }.tint(ButlerTheme.gold)
                    }
            }
        } header: {
            Text(filter == .all ? "Reminders" : "Upcoming").foregroundStyle(ButlerTheme.inkSecondary)
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        let items = reminders.filter { $0.status == .completed && matches($0) }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        Section("Completed") {
            if items.isEmpty { Text("Nothing completed yet.").foregroundStyle(ButlerTheme.inkSecondary) }
            ForEach(items) { r in
                ReminderRow(reminder: r, now: now, onComplete: { Task { try? await env.reminders.reopen(r) } }, onSnooze: nil)
                    .contentShape(Rectangle())
                    .onTapGesture { editingReminder = r }
                    .listRowBackground(ButlerTheme.card)
                    .swipeActions { Button(role: .destructive) { Task { try? await env.reminders.delete(r) } } label: { Label("Delete", systemImage: "trash") } }
            }
        }
    }

    private var memoryResults: [Memory] {
        if query.isEmpty { return memories.filter { !$0.isArchived } }
        var seen = Set<UUID>()
        return (env.memories.search(query, includeArchived: filter == .memories, limit: 50) + env.memories.textSearch(query)).filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder
    private var memoriesSection: some View {
        let items = memoryResults
        Section {
            if items.isEmpty {
                Text(query.isEmpty ? "Nothing remembered yet. Say “Remember that…”." : "No notes match “\(query)”.").foregroundStyle(ButlerTheme.inkSecondary)
            }
            ForEach(items) { m in
                NavigationLink(value: m.id) { MemoryRow(memory: m) }
                    .listRowBackground(ButlerTheme.card)
                    .swipeActions {
                        Button(role: .destructive) { try? env.memories.delete(m) } label: { Label("Delete", systemImage: "trash") }
                        Button { try? env.memories.apply(MemoryChanges(isArchived: !m.isArchived), to: m) } label: {
                            Label(m.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                        }.tint(ButlerTheme.attention)
                    }
            }
        } header: {
            Text("Memories").foregroundStyle(ButlerTheme.inkSecondary)
        }
    }

    @ViewBuilder
    private var needsAttentionSection: some View {
        let items = inbox.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        Section {
            if items.isEmpty { Text("Nothing waiting. Everything you said has been handled.").foregroundStyle(ButlerTheme.inkSecondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.text).font(.body).foregroundStyle(ButlerTheme.ink)
                    HStack(spacing: 6) {
                        Image(systemName: item.source == .voice ? "mic" : "keyboard")
                        Text(item.reason.displayName)
                        Text("·")
                        Text(Self.relative(item.capturedAt))
                    }
                    .font(.caption).foregroundStyle(ButlerTheme.inkSecondary)
                    HStack {
                        Button {
                            retrying = item.id
                            Task { retryResult = await env.assistant.retry(item); retrying = nil }
                        } label: {
                            if retrying == item.id { ProgressView().controlSize(.small) } else { Label("Try again", systemImage: "arrow.clockwise") }
                        }
                        .disabled(retrying != nil)
                        Button { inboxToReminder = item } label: { Label("Reminder", systemImage: "bell") }
                        Button { inboxToMemory = item } label: { Label("Note", systemImage: "book.closed") }
                    }
                    .buttonStyle(.bordered)
                    .tint(ButlerTheme.ink)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .listRowBackground(ButlerTheme.card)
                .swipeActions { Button(role: .destructive) { env.inbox.delete(item) } label: { Label("Delete", systemImage: "trash") } }
            }
        } header: {
            Label("Needs attention", systemImage: "tray.full").foregroundStyle(ButlerTheme.attention)
        } footer: {
            if !items.isEmpty {
                Text("These are things I heard but couldn't act on. One tap turns each into a reminder or a note.").foregroundStyle(ButlerTheme.inkSecondary)
            }
        }
    }

    /// A fixed relative string (not a self-updating Text) so the list stays quiet for accessibility.
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Inbox conversions

    private func prefillReminder(_ item: InboxItem) -> ReminderDraft {
        let interpreter = RuleBasedInterpreter(calendar: env.settings.calendar, now: Date(), defaults: env.settings.timeDefaults)
        if case .createReminder(let d) = interpreter.interpret(item.text) { return d }
        if let d = interpreter.parseReminder(NaturalDateParser.normalize(item.text)) { return d }
        return ReminderDraft(title: item.text)
    }

    private func prefillMemory(_ item: InboxItem) -> MemoryDraft {
        let interpreter = RuleBasedInterpreter(calendar: env.settings.calendar, now: Date(), defaults: env.settings.timeDefaults)
        if case .saveMemory(let m) = interpreter.interpret(item.text) { return m }
        return MemoryDraft(title: RuleBasedInterpreter.summaryTitle(item.text), content: item.text, category: RuleBasedInterpreter.classifyMemory(item.text.lowercased()),
                           people: RuleBasedInterpreter.extractPeople(from: item.text.lowercased()))
    }
}
