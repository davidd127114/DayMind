import Foundation
import Observation
import SwiftData
import UserNotifications
import os
import DayMindCore

/// Composition root. Builds the store and every service once and hands them to the views,
/// the assistant, App Intents and the notification delegate.
@MainActor
@Observable
final class AppEnvironment {
    static let shared: AppEnvironment = {
        let settings = SettingsStore()
        return AppEnvironment(settings: settings, inMemory: false, cloudKit: settings.cloudSyncEnabled, notifications: LocalNotificationScheduler())
    }()

    let settings: SettingsStore
    let store: DataStore
    let notifications: NotificationScheduling
    let people: PersonService
    let projects: ProjectService
    let reminders: ReminderService
    let memories: MemoryService
    let inbox: InboxService
    let conversation: ConversationService
    let briefing: BriefingService
    let exportImport: ExportImportService
    let actions: AssistantActions
    let assistant: AssistantEngine
    let router = AppRouter()
    let voice: VoiceController
    private(set) var storeError: String?
    private(set) var notificationStatus: String = "Unknown"
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "App")
    private var launched = false

    init(settings: SettingsStore, inMemory: Bool, cloudKit: Bool, notifications: NotificationScheduling, provider: AIProvider? = AppEnvironment.defaultProvider()) {
        self.settings = settings
        self.notifications = notifications
        var storeError: String?
        let store: DataStore
        do {
            store = try DataStore(inMemory: inMemory, cloudKit: cloudKit)
        } catch {
            // Last resort so the app still opens: an in-memory store plus a visible warning.
            storeError = "The database could not be opened (\(error.localizedDescription)). Data will not be saved until the app is reinstalled."
            guard let fallback = try? DataStore(inMemory: true) else { fatalError("Unable to create even an in-memory store: \(error)") }
            store = fallback
        }
        self.store = store
        self.storeError = storeError
        people = PersonService(store: store)
        projects = ProjectService(store: store)
        reminders = ReminderService(store: store, notifications: notifications, settings: settings, people: people, projects: projects)
        memories = MemoryService(store: store, settings: settings, people: people, projects: projects)
        inbox = InboxService(store: store)
        conversation = ConversationService(store: store, settings: settings)
        briefing = BriefingService(reminders: reminders, inbox: inbox, memories: memories, settings: settings, notifications: notifications)
        exportImport = ExportImportService(store: store, settings: settings, reminders: reminders)
        actions = AssistantActions(reminders: reminders, memories: memories, projects: projects, people: people, briefing: briefing, settings: settings)
        assistant = AssistantEngine(provider: provider, actions: actions, inbox: inbox, conversation: conversation, settings: settings)
        voice = VoiceController(settings: settings)
    }

    /// The only provider shipped: Apple's on-device model. Returns nil on builds/OS versions without it.
    static func defaultProvider() -> AIProvider? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return AppleIntelligenceProvider() }
        #endif
        return nil
    }

    // MARK: Lifecycle

    func onLaunch() async {
        guard !launched else { return }
        launched = true
        await syncPreferencesWithDatabase()
        if SampleData.isRequestedByEnvironment, !settings.hasSeededSampleData, reminders.fetchAll().isEmpty, memories.fetchAll(includeArchived: true).isEmpty {
            await SampleData.seed(into: self)
        }
        await onForeground()
        await assistant.provider?.prewarm()
    }

    func onForeground() async {
        conversation.purgeExpired()
        await reminders.rollForwardRecurring()
        await reminders.reconcileNotifications()
        await briefing.refreshSchedule()
        assistant.refreshAvailability()
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        switch await notifications.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Denied — enable in Settings → Notifications → DayMind"
        case .notDetermined: notificationStatus = "Not asked yet"
        @unknown default: notificationStatus = "Unknown"
        }
    }

    func requestNotificationPermission() async -> Bool {
        let granted = await notifications.requestAuthorization()
        await refreshNotificationStatus()
        if granted { await reminders.reconcileNotifications() }
        return granted
    }

    // MARK: Preferences mirror (lets settings ride along with CloudKit)

    private func syncPreferencesWithDatabase() async {
        let context = store.context
        let prefs = (try? context.fetch(FetchDescriptor<UserPreferences>()))?.first ?? {
            let p = UserPreferences()
            context.insert(p)
            return p
        }()
        let brief = (try? context.fetch(FetchDescriptor<BriefingSettings>()))?.first ?? {
            let b = BriefingSettings()
            context.insert(b)
            return b
        }()
        let lastSync = UserDefaults.standard.object(forKey: "settings.lastDatabaseSync") as? Date ?? .distantPast
        if prefs.lastModified > lastSync.addingTimeInterval(5) {
            // Another device changed preferences: adopt them.
            settings.timeZoneIdentifier = prefs.timeZoneIdentifier
            settings.timeDefaults = prefs.timeDefaults
            settings.transcriptRetention = prefs.transcriptRetention
            settings.voiceIdentifier = prefs.voiceIdentifier
            settings.speechRate = prefs.speechRate
            settings.speakResponses = prefs.speakResponses
            settings.briefingEnabled = brief.isEnabled
            settings.briefingTime = brief.time
        }
        writePreferencesToDatabase(prefs: prefs, brief: brief)
    }

    func persistPreferences() {
        let context = store.context
        let prefs = (try? context.fetch(FetchDescriptor<UserPreferences>()))?.first ?? { let p = UserPreferences(); context.insert(p); return p }()
        let brief = (try? context.fetch(FetchDescriptor<BriefingSettings>()))?.first ?? { let b = BriefingSettings(); context.insert(b); return b }()
        writePreferencesToDatabase(prefs: prefs, brief: brief)
    }

    private func writePreferencesToDatabase(prefs: UserPreferences, brief: BriefingSettings) {
        prefs.timeZoneIdentifier = settings.timeZoneIdentifier
        prefs.timeDefaults = settings.timeDefaults
        prefs.transcriptRetention = settings.transcriptRetention
        prefs.voiceIdentifier = settings.voiceIdentifier
        prefs.speechRate = settings.speechRate
        prefs.speakResponses = settings.speakResponses
        prefs.lastModified = Date()
        brief.isEnabled = settings.briefingEnabled
        brief.time = settings.briefingTime
        brief.lastModified = Date()
        try? store.save()
        UserDefaults.standard.set(Date(), forKey: "settings.lastDatabaseSync")
    }

    // MARK: Destructive

    func deleteAllData() async throws {
        try store.deleteEverything()
        await notifications.removeAll()
        conversation.clear()
        settings.resetAll()
        actions.focusReminderID = nil
        actions.lastSavedMemoryID = nil
    }
}
