import Foundation
import Observation
import SwiftData
import os

/// Owns the SwiftData `ModelContainer`. Local storage always works; CloudKit is layered on only
/// when the user enabled it *and* the container could be created with CloudKit.
@MainActor
@Observable
final class DataStore {
    /// Incremented on every successful save. Views read it to refresh immediately after edits/deletes.
    private(set) var changeCount = 0

    enum CloudStatus: Equatable {
        case disabled
        case active
        case failed(String)

        var displayText: String {
            switch self {
            case .disabled: return "Off — data stays on this iPhone"
            case .active: return "On — syncing with your private iCloud"
            case .failed(let why): return "Unavailable — \(why)"
            }
        }
    }

    let container: ModelContainer
    let cloudStatus: CloudStatus
    let isInMemory: Bool

    var context: ModelContext { container.mainContext }

    private static let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "DataStore")

    /// - Parameters:
    ///   - inMemory: used by unit tests and previews.
    ///   - cloudKit: attempt private CloudKit sync. Falls back to local-only if the entitlement or
    ///     iCloud account is missing, and reports why in `cloudStatus`.
    init(inMemory: Bool = false, cloudKit: Bool = false) throws {
        let schema = Schema(versionedSchema: DayMindSchemaV1.self)
        isInMemory = inMemory

        if inMemory {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [config])
            cloudStatus = .disabled
            return
        }

        if cloudKit {
            let cloudConfig = ModelConfiguration("DayMind", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                                 groupContainer: .none, cloudKitDatabase: .automatic)
            do {
                container = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [cloudConfig])
                cloudStatus = .active
                Self.logger.info("Store opened with CloudKit sync")
                return
            } catch {
                Self.logger.error("CloudKit container failed; falling back to local store: \(error.localizedDescription, privacy: .public)")
                let localConfig = ModelConfiguration("DayMind", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                                     groupContainer: .none, cloudKitDatabase: .none)
                container = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [localConfig])
                cloudStatus = .failed(Self.friendlyCloudError(error))
                return
            }
        }

        let localConfig = ModelConfiguration("DayMind", schema: schema, isStoredInMemoryOnly: false, allowsSave: true,
                                             groupContainer: .none, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, migrationPlan: DayMindMigrationPlan.self, configurations: [localConfig])
        cloudStatus = .disabled
    }

    static func friendlyCloudError(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("entitlement") || text.contains("container") { return "the iCloud capability is not enabled for this build" }
        if text.contains("account") || text.contains("not logged") { return "no iCloud account is signed in" }
        return "iCloud could not be reached"
    }

    func save() throws {
        if context.hasChanges { try context.save() }
        changeCount += 1
    }

    /// Removes every record. Used by Settings → Delete All Data (after confirmation) and by tests.
    func deleteEverything() throws {
        try context.delete(model: Reminder.self)
        try context.delete(model: Memory.self)
        try context.delete(model: Person.self)
        try context.delete(model: Project.self)
        try context.delete(model: ConversationTurn.self)
        try context.delete(model: InboxItem.self)
        try context.delete(model: UserPreferences.self)
        try context.delete(model: BriefingSettings.self)
        try context.save()
        changeCount += 1
    }
}
