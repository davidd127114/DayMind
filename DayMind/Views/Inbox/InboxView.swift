import SwiftUI
import SwiftData
import DayMindCore

struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Query(filter: #Predicate<InboxItem> { !$0.isResolved }, sort: \InboxItem.capturedAt, order: .reverse) private var items: [InboxItem]
    @State private var reminderFor: InboxItem?
    @State private var memoryFor: InboxItem?
    @State private var retryResult: AssistantResult?
    @State private var retrying: UUID?

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView("Inbox is empty", systemImage: "tray", description: Text("Anything DayMind couldn't process is kept here so nothing you say is lost."))
                }
                if let retryResult {
                    Section("Last retry") {
                        Text(retryResult.responseText).font(.footnote)
                        ForEach(retryResult.actions) { ActionCardView(record: $0) }
                    }
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text).font(.body)
                        HStack(spacing: 6) {
                            Image(systemName: item.source == .voice ? "mic" : "keyboard")
                            Text(item.reason.displayName)
                            Text("·")
                            Text(item.capturedAt, style: .relative)
                            Text("ago")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if let detail = item.detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                        HStack {
                            Button {
                                retrying = item.id
                                Task {
                                    retryResult = await env.assistant.retry(item)
                                    retrying = nil
                                }
                            } label: {
                                if retrying == item.id { ProgressView().controlSize(.small) } else { Label("Retry", systemImage: "arrow.clockwise") }
                            }
                            .disabled(retrying != nil)
                            Button { reminderFor = item } label: { Label("Reminder", systemImage: "bell") }
                            Button { memoryFor = item } label: { Label("Memory", systemImage: "brain") }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) { env.inbox.delete(item) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Inbox")
            .toolbar { SettingsToolbarButton() }
            .sheet(item: $reminderFor) { item in
                NavigationStack { ReminderEditorView(mode: .create(prefill: prefillReminder(item)), inboxItemToResolve: item) }
            }
            .sheet(item: $memoryFor) { item in
                NavigationStack { MemoryEditorView(mode: .create(prefill: prefillMemory(item)), inboxItemToResolve: item) }
            }
        }
    }

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
