import SwiftUI
import SwiftData
import DayMindCore

struct MemoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Memory.createdAt, order: .reverse) private var allMemories: [Memory]
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Project.name) private var projects: [Project]

    @State private var query = ""
    @State private var smartSearch = true
    @State private var category: MemoryCategory?
    @State private var person: Person?
    @State private var project: Project?
    @State private var showArchived = false
    @State private var creating = false

    private var results: [Memory] {
        var pool: [Memory]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            pool = allMemories
        } else if smartSearch {
            pool = env.memories.search(trimmed, includeArchived: showArchived, limit: 100)
        } else {
            pool = env.memories.textSearch(trimmed)
        }
        if !showArchived { pool = pool.filter { !$0.isArchived } }
        if let category { pool = pool.filter { $0.category == category } }
        if let person { pool = pool.filter { ($0.people ?? []).contains { $0.id == person.id } } }
        if let project { pool = pool.filter { $0.project?.id == project.id } }
        return pool
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Search mode", selection: $smartSearch) {
                        Text("Smart").tag(true)
                        Text("Exact text").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Search mode")
                    filterChips
                }
                Section(results.isEmpty ? "No memories" : "\(results.count) memor\(results.count == 1 ? "y" : "ies")") {
                    ForEach(results) { m in
                        NavigationLink(value: m.id) { MemoryRow(memory: m) }
                            .swipeActions {
                                Button(role: .destructive) { try? env.memories.delete(m) } label: { Label("Delete", systemImage: "trash") }
                                Button { try? env.memories.apply(MemoryChanges(isArchived: !m.isArchived), to: m) } label: {
                                    Label(m.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                                }.tint(.orange)
                            }
                    }
                }
            }
            .searchable(text: $query, prompt: "Ask: what did I say about Michael?")
            .navigationTitle("Memories")
            .navigationDestination(for: UUID.self) { id in
                if let m = env.memories.fetch(id: id) { MemoryDetailView(memory: m) } else { Text("Memory not found") }
            }
            .toolbar {
                SettingsToolbarButton()
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New memory")
                }
            }
            .sheet(isPresented: $creating) { NavigationStack { MemoryEditorView(mode: .create(prefill: nil)) } }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("All categories") { category = nil }
                    ForEach(MemoryCategory.allCases) { c in Button(c.displayName) { category = c } }
                } label: { chip(category?.displayName ?? "Category", systemImage: "tag", active: category != nil) }
                Menu {
                    Button("Anyone") { person = nil }
                    ForEach(people) { p in Button(p.name) { person = p } }
                } label: { chip(person?.name ?? "Person", systemImage: "person", active: person != nil) }
                Menu {
                    Button("Any project") { project = nil }
                    ForEach(projects) { p in Button(p.name) { project = p } }
                } label: { chip(project?.name ?? "Project", systemImage: "folder", active: project != nil) }
                Toggle(isOn: $showArchived) { Text("Archived") }
                    .toggleStyle(.button).font(.footnote)
            }
        }
    }

    private func chip(_ text: String, systemImage: String, active: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct MemoryRow: View {
    let memory: Memory
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: memory.category.systemImageName).foregroundStyle(.teal)
                Text(memory.title).font(.body.weight(.medium))
                if memory.importance == .high { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                if memory.isArchived { Text("Archived").tagStyle(.gray) }
            }
            Text(memory.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                ForEach(memory.peopleNames, id: \.self) { Text($0).tagStyle(.blue) }
                if let p = memory.project { Text(p.name).tagStyle(.purple) }
                ForEach(memory.tags, id: \.self) { Text("#\($0)").tagStyle(.gray) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct MemoryDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let memory: Memory
    @State private var editing = false

    var body: some View {
        List {
            Section {
                Text(memory.content).font(.body)
                LabeledContent("Category", value: memory.category.displayName)
                LabeledContent("Importance", value: memory.importance.displayName)
                if !memory.peopleNames.isEmpty { LabeledContent("People", value: memory.peopleNames.joined(separator: ", ")) }
                if let p = memory.project { LabeledContent("Project", value: p.name) }
                if !memory.tags.isEmpty { LabeledContent("Tags", value: memory.tags.map { "#\($0)" }.joined(separator: " ")) }
            }
            Section("History") {
                LabeledContent("Saved", value: memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let accessed = memory.lastAccessedAt { LabeledContent("Last used", value: accessed.formatted(date: .abbreviated, time: .shortened)) }
                if let t = memory.originalTranscript { LabeledContent("Original words", value: t) }
            }
            Section {
                Button(memory.isArchived ? "Unarchive" : "Archive") { try? env.memories.apply(MemoryChanges(isArchived: !memory.isArchived), to: memory) }
                Button("Delete memory", role: .destructive) { try? env.memories.delete(memory); dismiss() }
            }
        }
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
            Section("Memory") {
                TextField("What to remember", text: $content, axis: .vertical).lineLimit(3...8)
                TextField("Short title (optional)", text: $title)
                Picker("Category", selection: $category) { ForEach(MemoryCategory.allCases) { Text($0.displayName).tag($0) } }
                Picker("Importance", selection: $importance) { ForEach(Importance.allCases) { Text($0.displayName).tag($0) } }
            }
            Section("Related") {
                TextField("People (comma separated)", text: $peopleText)
                TextField("Tags (comma separated)", text: $tagsText)
                Picker("Project", selection: $projectID) {
                    Text("None").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(isEditing ? "Edit Memory" : "New Memory")
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
