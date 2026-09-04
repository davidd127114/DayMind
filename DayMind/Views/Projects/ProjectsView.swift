import SwiftUI
import SwiftData
import DayMindCore

struct ProjectsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var newName = ""
    @State private var creating = false
    @State private var showArchived = false

    private var visible: [Project] { projects.filter { showArchived || !$0.isArchived } }

    var body: some View {
        NavigationStack {
            List {
                if visible.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Say “save this under the kitchen renovation project” or tap + to create one."))
                }
                ForEach(visible) { p in
                    NavigationLink(value: p.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(p.name).font(.body.weight(.medium))
                                if p.isArchived { Text("Archived").tagStyle(.gray) }
                            }
                            if !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text("\((p.reminders ?? []).filter { $0.isPending }.count) open reminders · \((p.memories ?? []).count) memories")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { try? env.projects.delete(p) } label: { Label("Delete", systemImage: "trash") }
                        Button { try? env.projects.update(p, isArchived: !p.isArchived) } label: { Label(p.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.orange)
                    }
                }
                Toggle("Show archived", isOn: $showArchived)
            }
            .navigationTitle("Projects")
            .navigationDestination(for: UUID.self) { id in
                if let p = env.projects.fetch(id: id) { ProjectDetailView(project: p) } else { Text("Project not found") }
            }
            .toolbar {
                SettingsToolbarButton()
                ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New project") }
            }
            .alert("New project", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { env.projects.create(name: name) }
                    newName = ""
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
        }
    }
}

struct ProjectDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let project: Project
    @State private var summary = ""
    @State private var addingNote = false
    @State private var addingReminder = false
    @State private var editingReminder: Reminder?

    private var reminders: [Reminder] { (project.reminders ?? []).sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) } }
    private var memories: [Memory] { (project.memories ?? []).sorted { $0.createdAt > $1.createdAt } }
    private var people: [Person] {
        var seen = Set<UUID>()
        return (reminders.flatMap { $0.people ?? [] } + memories.flatMap { $0.people ?? [] }).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section("Notes") {
                TextField("Project summary", text: $summary, axis: .vertical)
                    .onSubmit { try? env.projects.update(project, summary: summary) }
                    .onChange(of: summary) { _, new in try? env.projects.update(project, summary: new) }
                Button { addingNote = true } label: { Label("Add a note to this project", systemImage: "plus") }
            }
            Section("Reminders (\(reminders.filter { $0.isPending }.count) open)") {
                ForEach(reminders) { r in
                    ReminderRow(reminder: r, now: Date(), onComplete: { Task { _ = try? await env.reminders.complete(r) } }, onSnooze: nil)
                        .onTapGesture { editingReminder = r }
                }
                Button { addingReminder = true } label: { Label("Add reminder", systemImage: "bell.badge") }
            }
            Section("Memories (\(memories.count))") {
                ForEach(memories) { m in NavigationLink(value: m.id) { MemoryRow(memory: m) } }
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people) { p in
                        Label(p.name, systemImage: "person")
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationDestination(for: UUID.self) { id in
            if let m = env.memories.fetch(id: id) { MemoryDetailView(memory: m) } else { Text("Not found") }
        }
        .onAppear { summary = project.summary }
        .sheet(isPresented: $addingNote) {
            NavigationStack { MemoryEditorView(mode: .create(prefill: MemoryDraft(title: "", content: "", category: .project, projectName: project.name))) }
        }
        .sheet(isPresented: $addingReminder) {
            NavigationStack { ReminderEditorView(mode: .create(prefill: ReminderDraft(title: "", dueDate: Date().addingTimeInterval(3600), hasExplicitTime: true, projectName: project.name))) }
        }
        .sheet(item: $editingReminder) { r in NavigationStack { ReminderEditorView(mode: .edit(r)) } }
    }
}
