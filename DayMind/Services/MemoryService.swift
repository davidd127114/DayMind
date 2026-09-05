import Foundation
import SwiftData
import DayMindCore

enum MemoryServiceError: LocalizedError, Equatable {
    case emptyContent
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyContent: return "There was nothing to remember."
        case .notFound: return "I couldn't find that memory."
        }
    }
}

struct MemoryChanges: Equatable, Sendable {
    var title: String?
    var content: String?
    var category: MemoryCategory?
    var tags: [String]?
    var importance: Importance?
    var people: [String]?
    var projectName: String??
    var isArchived: Bool?

    init(title: String? = nil, content: String? = nil, category: MemoryCategory? = nil, tags: [String]? = nil, importance: Importance? = nil, people: [String]? = nil, projectName: String?? = nil, isArchived: Bool? = nil) {
        self.title = title; self.content = content; self.category = category; self.tags = tags; self.importance = importance; self.people = people; self.projectName = projectName; self.isArchived = isArchived
    }
}

@MainActor
final class MemoryService {
    private let store: DataStore
    private let settings: SettingsStore
    private let people: PersonService
    private let projects: ProjectService
    var storeRef: DataStore { store }
    var peopleService: PersonService { people }
    var projectService: ProjectService { projects }

    init(store: DataStore, settings: SettingsStore, people: PersonService, projects: ProjectService) {
        self.store = store
        self.settings = settings
        self.people = people
        self.projects = projects
    }

    private var context: ModelContext { store.context }

    @discardableResult
    func create(from draft: MemoryDraft, transcript: String?) throws -> Memory {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryServiceError.emptyContent }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory = Memory(title: title.isEmpty ? RuleBasedInterpreter.summaryTitle(content) : title, content: content, category: draft.category,
                            tags: Self.normalizeTags(draft.tags), importance: draft.importance,
                            originalTranscript: settings.transcriptRetention == .never ? nil : transcript)
        memory.people = draft.people.map { people.findOrCreate(name: $0) }
        if let name = draft.projectName, !name.isEmpty { memory.project = projects.findOrCreate(name: name) }
        context.insert(memory)
        try store.save()
        return memory
    }

    func apply(_ changes: MemoryChanges, to memory: Memory) throws {
        if let title = changes.title { memory.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let content = changes.content {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MemoryServiceError.emptyContent }
            memory.content = trimmed
        }
        if let category = changes.category { memory.category = category }
        if let tags = changes.tags { memory.tags = Self.normalizeTags(tags) }
        if let importance = changes.importance { memory.importance = importance }
        if let names = changes.people { memory.people = names.map { people.findOrCreate(name: $0) } }
        if let project = changes.projectName { memory.project = project.flatMap { $0.isEmpty ? nil : projects.findOrCreate(name: $0) } }
        if let archived = changes.isArchived { memory.isArchived = archived }
        memory.touch()
        try store.save()
    }

    func delete(_ memory: Memory) throws {
        context.delete(memory)
        try store.save()
    }

    func deleteAll() throws -> Int {
        let all = fetchAll(includeArchived: true)
        for m in all { context.delete(m) }
        try store.save()
        return all.count
    }

    func touch(_ memory: Memory) {
        memory.lastAccessedAt = Date()
        try? store.save()
    }

    // MARK: Queries

    func fetchAll(includeArchived: Bool = false) -> [Memory] {
        let d = FetchDescriptor<Memory>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? context.fetch(d)) ?? []
        return includeArchived ? all : all.filter { !$0.isArchived }
    }

    func fetch(id: UUID) -> Memory? {
        var d = FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func mostRecent() -> Memory? { fetchAll().first }

    /// Ranked natural-language search over title, content, tags, people and project.
    func search(_ query: String, personName: String? = nil, projectName: String? = nil, includeArchived: Bool = false, limit: Int = 10) -> [Memory] {
        var pool = fetchAll(includeArchived: includeArchived)
        if let personName, !personName.isEmpty {
            pool = pool.filter { $0.peopleNames.contains { $0.localizedCaseInsensitiveCompare(personName) == .orderedSame } || $0.content.localizedCaseInsensitiveContains(personName) }
        }
        if let projectName, !projectName.isEmpty {
            pool = pool.filter { ($0.project?.name ?? "").localizedCaseInsensitiveCompare(projectName) == .orderedSame }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(pool.prefix(limit)) }
        let ranked = TextMatching.rank(pool, query: q, text: { m in
            "\(m.title) \(m.content) \(m.tags.joined(separator: " ")) \(m.peopleNames.joined(separator: " ")) \(m.project?.name ?? "")"
        }, threshold: 0.34)
        let results = ranked.map(\.item)
        for m in results.prefix(limit) { m.lastAccessedAt = Date() }
        try? store.save()
        return Array(results.prefix(limit))
    }

    /// Plain substring search (fallback that never needs ranking heuristics).
    func textSearch(_ query: String) -> [Memory] {
        let q = query.lowercased()
        guard !q.isEmpty else { return fetchAll() }
        return fetchAll(includeArchived: true).filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } || $0.peopleNames.contains { $0.lowercased().contains(q) }
        }
    }

    func forProject(_ project: Project) -> [Memory] { fetchAll(includeArchived: true).filter { $0.project?.id == project.id } }
    func forPerson(_ person: Person) -> [Memory] { fetchAll(includeArchived: true).filter { ($0.people ?? []).contains { $0.id == person.id } } }

    static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - People & projects

@MainActor
final class PersonService {
    private let store: DataStore
    init(store: DataStore) { self.store = store }

    func all() -> [Person] {
        let d = FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)])
        return (try? store.context.fetch(d)) ?? []
    }

    func find(name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all().first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func findOrCreate(name: String) -> Person {
        if let existing = find(name: name) { return existing }
        let p = Person(name: RuleBasedInterpreter.titleCase(name.trimmingCharacters(in: .whitespacesAndNewlines)))
        store.context.insert(p)
        try? store.save()
        return p
    }

    func delete(_ person: Person) throws {
        store.context.delete(person)
        try store.save()
    }
}

@MainActor
final class ProjectService {
    private let store: DataStore
    init(store: DataStore) { self.store = store }

    func all(includeArchived: Bool = false) -> [Project] {
        let d = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        let all = (try? store.context.fetch(d)) ?? []
        return includeArchived ? all : all.filter { !$0.isArchived }
    }

    func fetch(id: UUID) -> Project? {
        var d = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? store.context.fetch(d).first
    }

    func find(name: String) -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all(includeArchived: true).first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) { return exact }
        return TextMatching.rank(all(includeArchived: true), query: trimmed, text: { $0.name }, threshold: 0.6).first?.item
    }

    func findOrCreate(name: String) -> Project {
        if let existing = find(name: name) { return existing }
        return create(name: name)
    }

    @discardableResult
    func create(name: String, summary: String = "") -> Project {
        let p = Project(name: RuleBasedInterpreter.titleCase(name.trimmingCharacters(in: .whitespacesAndNewlines)), summary: summary)
        store.context.insert(p)
        try? store.save()
        return p
    }

    func update(_ project: Project, name: String? = nil, summary: String? = nil, isArchived: Bool? = nil) throws {
        if let name { project.name = name }
        if let summary { project.summary = summary }
        if let isArchived { project.isArchived = isArchived }
        try store.save()
    }

    func delete(_ project: Project) throws {
        store.context.delete(project)
        try store.save()
    }
}
