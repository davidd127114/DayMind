import SwiftUI
import SwiftData
import DayMindCore

struct MemoryDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var editing = false

    var body: some View {
        List {
            Section {
                Text(memory.content).font(.body).foregroundStyle(ButlerTheme.ink)
                LabeledContent("Kind", value: memory.category.displayName)
                LabeledContent("Importance", value: memory.importance.displayName)
                if !memory.peopleNames.isEmpty { LabeledContent("People", value: memory.peopleNames.joined(separator: ", ")) }
                if let p = memory.project { LabeledContent("Project", value: p.name) }
                if !memory.tags.isEmpty { LabeledContent("Tags", value: memory.tags.map { "#\($0)" }.joined(separator: " ")) }
            }
            .listRowBackground(ButlerTheme.card)
            Section("History") {
                LabeledContent("Saved", value: memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let accessed = memory.lastAccessedAt { LabeledContent("Last used", value: accessed.formatted(date: .abbreviated, time: .shortened)) }
                if let t = memory.originalTranscript { LabeledContent("Original words", value: t) }
            }
            .listRowBackground(ButlerTheme.card)
            Section {
                Button(memory.isArchived ? "Unarchive" : "Archive") { try? env.memories.apply(MemoryChanges(isArchived: !memory.isArchived), to: memory) }
                Button("Delete note", role: .destructive) { try? env.memories.delete(memory); dismiss() }
            }
            .listRowBackground(ButlerTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background(ButlerTheme.ivory)
        .navigationTitle(memory.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } } }
        .sheet(isPresented: $editing) { NavigationStack { MemoryEditorView(mode: .edit(memory)) } }
        .onAppear { env.memories.touch(memory) }
    }
}

struct MemoryEditorView: View {
    enum Mode { case create(prefill: MemoryDraft?), edit(Memory) }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.name) private var projects: [Project]
    let mode: Mode
    var inboxItemToResolve: InboxItem? = nil

    @State private var title = ""
    @State private var content = ""
    @State private var category: MemoryCategory = .fact
    @State private var importance: Importance = .normal
    @State private var peopleText = ""
    @State private var tagsText = ""
    @State private var projectID: UUID?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Note") {
                TextField("What to remember", text: $content, axis: .vertical).lineLimit(3...8)
                TextField("Short title (optional)", text: $title)
                Picker("Kind", selection: $category) { ForEach(MemoryCategory.allCases) { Text($0.displayName).tag($0) } }
                Picker("Importance", selection: $importance) { ForEach(Importance.allCases) { Text($0.displayName).tag($0) } }
            }
            Section("Optional details") {
                TextField("People (comma separated)", text: $peopleText)
                TextField("Tags (comma separated)", text: $tagsText)
                Picker("Project", selection: $projectID) {
                    Text("None").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(ButlerTheme.failure) } }
        }
        .navigationTitle(isEditing ? "Edit Note" : "New Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") { save() }.disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private var isEditing: Bool { if case .edit = mode { return true }; return false }

    private func load() {
        switch mode {
        case .create(let prefill):
            guard let prefill else { return }
            title = prefill.title
            content = prefill.content
            category = prefill.category
            importance = prefill.importance
            peopleText = prefill.people.joined(separator: ", ")
            tagsText = prefill.tags.joined(separator: ", ")
            if let name = prefill.projectName, let p = env.projects.find(name: name) { projectID = p.id }
            if category == .fact, !content.isEmpty { category = RuleBasedInterpreter.classifyMemory(content.lowercased()) }
        case .edit(let m):
            title = m.title; content = m.content; category = m.category; importance = m.importance
            peopleText = m.peopleNames.joined(separator: ", "); tagsText = m.tags.joined(separator: ", "); projectID = m.project?.id
        }
    }

    private func save() {
        let people = peopleText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let projectName = projectID.flatMap { env.projects.fetch(id: $0)?.name }
        do {
            switch mode {
            case .create:
                _ = try env.memories.create(from: MemoryDraft(title: title, content: content, category: category, people: people, projectName: projectName, tags: tags, importance: importance), transcript: nil)
                if let inboxItemToResolve { env.inbox.markResolved(inboxItemToResolve) }
            case .edit(let m):
                try env.memories.apply(MemoryChanges(title: title.isEmpty ? RuleBasedInterpreter.summaryTitle(content) : title, content: content, category: category, tags: tags, importance: importance, people: people, projectName: .some(projectName)), to: m)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
