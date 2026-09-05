import Foundation
import Observation
import DayMindCore

/// User preferences backed by `UserDefaults` (fast, available before the database opens) and
/// mirrored into the `UserPreferences` / `BriefingSettings` SwiftData rows so they can sync.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        timeZoneIdentifier = defaults.string(forKey: Keys.timeZone)
        timeDefaults = DayMindJSON.decode(TimeDefaults.self, from: defaults.data(forKey: Keys.timeDefaults)) ?? .standard
        briefingEnabled = defaults.bool(forKey: Keys.briefingEnabled)
        briefingTime = DayMindJSON.decode(TimeOfDay.self, from: defaults.data(forKey: Keys.briefingTime)) ?? TimeOfDay(hour: 8)
        transcriptRetention = TranscriptRetention(rawValue: defaults.string(forKey: Keys.transcriptRetention) ?? "") ?? .thirtyDays
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 0.5
        speakResponses = defaults.object(forKey: Keys.speakResponses) as? Bool ?? true
        cloudSyncEnabled = defaults.bool(forKey: Keys.cloudSyncEnabled)
        preferOnDeviceSpeech = defaults.object(forKey: Keys.preferOnDeviceSpeech) as? Bool ?? true
        hasSeededSampleData = defaults.bool(forKey: Keys.hasSeededSampleData)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        autoStartListeningOnOpen = defaults.object(forKey: Keys.autoStartListening) as? Bool ?? true
        lastDatabaseSync = defaults.object(forKey: Keys.lastDatabaseSync) as? Date ?? .distantPast
        polishReminders = defaults.bool(forKey: Keys.polishReminders)
    }

    private enum Keys {
        static let timeZone = "settings.timeZoneIdentifier"
        static let timeDefaults = "settings.timeDefaults"
        static let briefingEnabled = "settings.briefingEnabled"
        static let briefingTime = "settings.briefingTime"
        static let transcriptRetention = "settings.transcriptRetention"
        static let voiceIdentifier = "settings.voiceIdentifier"
        static let speechRate = "settings.speechRate"
        static let speakResponses = "settings.speakResponses"
        static let cloudSyncEnabled = "settings.cloudSyncEnabled"
        static let preferOnDeviceSpeech = "settings.preferOnDeviceSpeech"
        static let hasSeededSampleData = "settings.hasSeededSampleData"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let autoStartListening = "settings.autoStartListeningOnOpen"
        static let lastDatabaseSync = "settings.lastDatabaseSync"
        static let polishReminders = "settings.polishReminders"
    }

    /// `nil` means "follow the iPhone's current time zone".
    var timeZoneIdentifier: String? { didSet { defaults.set(timeZoneIdentifier, forKey: Keys.timeZone); bump() } }
    var timeDefaults: TimeDefaults { didSet { defaults.set(DayMindJSON.encode(timeDefaults), forKey: Keys.timeDefaults); bump() } }
    var briefingEnabled: Bool { didSet { defaults.set(briefingEnabled, forKey: Keys.briefingEnabled); bump() } }
    var briefingTime: TimeOfDay { didSet { defaults.set(DayMindJSON.encode(briefingTime), forKey: Keys.briefingTime); bump() } }
    var transcriptRetention: TranscriptRetention { didSet { defaults.set(transcriptRetention.rawValue, forKey: Keys.transcriptRetention); bump() } }
    var voiceIdentifier: String? { didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier); bump() } }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: Keys.speechRate); bump() } }
    var speakResponses: Bool { didSet { defaults.set(speakResponses, forKey: Keys.speakResponses); bump() } }
    /// Takes effect at next launch (the store is opened once).
    var cloudSyncEnabled: Bool { didSet { defaults.set(cloudSyncEnabled, forKey: Keys.cloudSyncEnabled) } }
    var preferOnDeviceSpeech: Bool { didSet { defaults.set(preferOnDeviceSpeech, forKey: Keys.preferOnDeviceSpeech) } }
    var hasSeededSampleData: Bool { didSet { defaults.set(hasSeededSampleData, forKey: Keys.hasSeededSampleData) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) } }
    var autoStartListeningOnOpen: Bool { didSet { defaults.set(autoStartListeningOnOpen, forKey: Keys.autoStartListening) } }
    /// When this device last wrote its preferences into the database (for the CloudKit mirror).
    var lastDatabaseSync: Date { didSet { defaults.set(lastDatabaseSync, forKey: Keys.lastDatabaseSync) } }
    /// Off by default. Tidies reminder titles (grammar, capitalisation) without changing meaning.
    var polishReminders: Bool { didSet { defaults.set(polishReminders, forKey: Keys.polishReminders) } }

    /// Incremented whenever a synced preference changes, so `PreferencesSync` can mirror it.
    private(set) var revision: Int = 0
    private func bump() { revision += 1 }

    var timeZone: TimeZone {
        if let id = timeZoneIdentifier, let tz = TimeZone(identifier: id) { return tz }
        return .current
    }

    var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = timeZone
        return c
    }

    func resetAll() {
        timeZoneIdentifier = nil
        timeDefaults = .standard
        briefingEnabled = false
        briefingTime = TimeOfDay(hour: 8)
        transcriptRetention = .thirtyDays
        voiceIdentifier = nil
        speechRate = 0.5
        speakResponses = true
        hasSeededSampleData = false
    }
}
