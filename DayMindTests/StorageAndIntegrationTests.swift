import XCTest
import SwiftData
import DayMindCore
@testable import DayMind

@MainActor
final class MemoryServiceTests: XCTestCase {
    func testSearchRanksAndFilters() throws {
        let (env, _) = TestEnv.make()
        _ = try env.memories.create(from: MemoryDraft(title: "Michael prefers afternoons", content: "Michael prefers afternoon appointments.", category: .preference, people: ["Michael"]), transcript: nil)
        _ = try env.memories.create(from: MemoryDraft(title: "Countertop", content: "We decided on quartz for the kitchen countertop.", category: .decision, projectName: "Kitchen Renovation"), transcript: nil)
        _ = try env.memories.create(from: MemoryDraft(title: "Old", content: "Archived note about nothing.", category: .other), transcript: nil)
        try env.memories.apply(MemoryChanges(isArchived: true), to: env.memories.fetchAll().first { $0.title == "Old" }!)

        XCTAssertEqual(env.memories.search("michael").map(\.title), ["Michael prefers afternoons"])
        XCTAssertEqual(env.memories.search("kitchen countertop").map(\.title), ["Countertop"])
        XCTAssertEqual(env.memories.search("quartz", projectName: "Kitchen Renovation").count, 1)
        XCTAssertTrue(env.memories.search("nothing").isEmpty, "archived memories are hidden by default")
        XCTAssertEqual(env.memories.search("nothing", includeArchived: true).count, 1)
        XCTAssertEqual(env.memories.textSearch("QUARTZ").count, 1)
        XCTAssertEqual(env.people.all().map(\.name), ["Michael"])
        XCTAssertEqual(env.projects.all().map(\.name), ["Kitchen Renovation"])
        XCTAssertNotNil(env.memories.search("michael").first?.lastAccessedAt)
    }

    func testDeleteAllMemoriesRequiresConfirmationThroughEngine() async throws {
        let (env, _) = TestEnv.make()
        _ = try env.memories.create(from: MemoryDraft(title: "A", content: "Fact A"), transcript: nil)
        let r = await env.assistant.handle("delete all my memories", source: .text)
        XCTAssertEqual(r.pending, .deleteAllMemories(count: 1))
        XCTAssertEqual(env.memories.fetchAll().count, 1)
        _ = await env.assistant.confirmPending()
        XCTAssertTrue(env.memories.fetchAll(includeArchived: true).isEmpty)
    }
}

@MainActor
final class ExportImportTests: XCTestCase {
    func testRoundTripThroughJSON() async throws {
        let (env, mock) = TestEnv.make()
        let due = Fixture.date(2026, 9, 3, 15, 0)
        let r = try await env.reminders.create(from: ReminderDraft(title: "Call Michael", dueDate: due, people: ["Michael"], projectName: "Kitchen Renovation"), transcript: "words"), _ = r
        _ = try env.memories.create(from: MemoryDraft(title: "Pref", content: "Michael prefers afternoons.", category: .preference, people: ["Michael"]), transcript: nil)
        env.inbox.add(text: "unclear thing", source: .voice, reason: .ambiguous)

        let url = try env.exportImport.exportToTemporaryFile()
        let data = try Data(contentsOf: url)
        let doc = try ExportDocument.decode(data)
        XCTAssertEqual(doc.reminders.count, 1)
        XCTAssertEqual(doc.memories.count, 1)
        XCTAssertEqual(doc.people.count, 1)
        XCTAssertEqual(doc.projects.count, 1)
        XCTAssertEqual(doc.inbox.count, 1)
        XCTAssertEqual(doc.preferences?.timeZoneIdentifier, "America/New_York")

        // Wipe and restore.
        try env.store.deleteEverything()
        mock.scheduled.removeAll()
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        let summary = try await env.exportImport.importData(data)
        XCTAssertEqual(summary.reminders, 1)
        XCTAssertEqual(summary.memories, 1)
        let restored = env.reminders.fetchAll()[0]
        XCTAssertEqual(restored.title, "Call Michael")
        XCTAssertEqual(restored.dueDate, due)
        XCTAssertEqual(restored.peopleNames, ["Michael"])
        XCTAssertEqual(restored.project?.name, "Kitchen Renovation")
        XCTAssertEqual(restored.originalTranscript, "words")
        XCTAssertNotNil(mock.scheduled[restored.notificationRequestIdentifier], "import reconciles notifications")

        // Importing the same file again is idempotent.
        let again = try await env.exportImport.importData(data)
        XCTAssertEqual(again.reminders, 0)
        XCTAssertEqual(env.reminders.fetchAll().count, 1)
    }

    func testImportRejectsNewerFormat() async throws {
        let (env, _) = TestEnv.make()
        var doc = try env.exportImport.exportDocument()
        doc.schemaVersion = 99
        let data = try DayMindJSON.encoder().encode(doc)
        do {
            _ = try await env.exportImport.importData(data)
            XCTFail("should reject")
        } catch {
            XCTAssertTrue(error is ExportDocument.ExportError)
        }
    }
}

@MainActor
final class SchemaAndMigrationTests: XCTestCase {
    func testStoreOpensWithMigrationPlanAndVersionedSchema() throws {
        let store = try DataStore(inMemory: true)
        XCTAssertEqual(DayMindSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(DayMindMigrationPlan.schemas.count, 1)
        XCTAssertTrue(DayMindMigrationPlan.stages.isEmpty)
        XCTAssertEqual(DayMindSchemaV1.models.count, 8)
        let reminder = Reminder(title: "x")
        store.context.insert(reminder)
        try store.save()
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<Reminder>()).count, 1)
        XCTAssertEqual(store.cloudStatus, .disabled)
    }

    func testOnDiskStoreMigratesAcrossRelaunch() throws {
        // Two containers over the same file simulate an app relaunch with the migration plan applied.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DayMindMigrationTest-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema(versionedSchema: DayMindSchemaV1.self)
        let config = ModelConfiguration("Test", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        let first = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [config])
        let ctx = ModelContext(first)
        ctx.insert(Memory(title: "Persisted", content: "Survives relaunch"))
        try ctx.save()

        let second = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [config])
        let ctx2 = ModelContext(second)
        let memories = try ctx2.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(memories.map(\.title), ["Persisted"])
    }

    func testPreferencesMirrorRowsExistAfterLaunch() async {
        let (env, mock) = TestEnv.make()
        env.settings.briefingEnabled = true
        env.settings.briefingTime = TimeOfDay(hour: 7, minute: 30)
        await env.onLaunch()
        let prefs = try? env.store.context.fetch(FetchDescriptor<UserPreferences>())
        XCTAssertEqual(prefs?.count, 1)
        XCTAssertEqual(prefs?.first?.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(mock.briefing?.time, TimeOfDay(hour: 7, minute: 30))
        XCTAssertEqual(mock.briefing?.title, "Your DayMind briefing")
    }
}

@MainActor
final class SampleDataTests: XCTestCase {
    func testSampleDataSeedsAndDeleteAllClears() async throws {
        let (env, mock) = TestEnv.make()
        await SampleData.seed(into: env)
        XCTAssertGreaterThanOrEqual(env.reminders.fetchAll().count, 5)
        XCTAssertGreaterThanOrEqual(env.memories.fetchAll().count, 4)
        XCTAssertEqual(env.projects.all().map(\.name), ["Kitchen Renovation"])
        XCTAssertEqual(env.inbox.unresolvedCount, 1)
        XCTAssertFalse(mock.scheduled.isEmpty)
        try await env.deleteAllData()
        XCTAssertTrue(env.reminders.fetchAll().isEmpty)
        XCTAssertTrue(env.memories.fetchAll(includeArchived: true).isEmpty)
        XCTAssertTrue(mock.scheduled.isEmpty)
    }
}
