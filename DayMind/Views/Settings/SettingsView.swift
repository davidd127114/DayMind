import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import DayMindCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var importing = false
    @State private var importMessage: String?
    @State private var confirmDeleteAll = false
    @State private var confirmSampleData = false
    @State private var previewVoiceTask: Task<Void, Never>?
    @State private var timeZoneSearch = ""

    private let voices = SpeechOutputService.availableVoices()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Voice") {
                Toggle("Speak responses", isOn: $settings.speakResponses)
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("System default").tag(String?.none)
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) (\(qualityName(v.quality)))").tag(String?.some(v.identifier))
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $settings.speechRate, in: 0...1) { Text("Speech speed") }
                }
                Button("Preview voice") {
                    previewVoiceTask?.cancel()
                    previewVoiceTask = Task { await env.voice.speak("Done. I'll remind you tomorrow at 3 PM.") }
                }
                Toggle("Prefer on-device speech recognition", isOn: $settings.preferOnDeviceSpeech)
                Text(env.voice.recognitionDisclosure).font(.caption).foregroundStyle(.secondary)
                Toggle("Start listening when opened from a shortcut", isOn: $settings.autoStartListeningOnOpen)
            }

            Section("Time") {
                NavigationLink {
                    TimeZonePicker(selection: $settings.timeZoneIdentifier)
                } label: {
                    LabeledContent("Time zone", value: settings.timeZoneIdentifier ?? "Device (\(TimeZone.current.identifier))")
                }
                timeRow("Morning means", \.morning)
                timeRow("Afternoon means", \.afternoon)
                timeRow("Evening means", \.evening)
                timeRow("Night means", \.night)
            }

            Section("Daily briefing") {
                Toggle("Daily briefing notification", isOn: $settings.briefingEnabled)
                if settings.briefingEnabled {
                    DatePicker("Time", selection: briefingDateBinding, displayedComponents: .hourAndMinute)
                    Text(env.briefing.composeText()).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                LabeledContent("Notifications", value: env.notificationStatus)
                if env.notificationStatus != "Allowed" {
                    Button("Allow notifications") { Task { _ = await env.requestNotificationPermission() } }
                    if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open iOS Settings", destination: url) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Apple Intelligence", value: env.assistant.lastAvailability.title)
                    Text(env.assistant.lastAvailability.detail).font(.caption).foregroundStyle(.secondary)
                    if let provider = env.assistant.provider {
                        Text(provider.costAndPrivacyNote).font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Check again") { env.assistant.refreshAvailability() }.font(.footnote)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("iCloud sync", value: env.store.cloudStatus.displayText)
                    Toggle("Sync with private iCloud (restart required)", isOn: $settings.cloudSyncEnabled)
                    Text("Uses only your private iCloud database. Nobody else, including the developer, can read it. Requires the iCloud capability in the build and an iCloud account on this iPhone.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Picker("Keep transcripts", selection: $settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Raw audio is never stored. Transcripts (the words you said) are kept for this long so you can see what created a reminder.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear conversation history") { env.conversation.clear() }
            }

            Section("Data") {
                Button { exportURL = try? env.exportImport.exportToTemporaryFile() } label: { Label("Export backup (JSON)", systemImage: "square.and.arrow.up") }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share the backup file", systemImage: "doc") }
                }
                Button { importing = true } label: { Label("Import backup", systemImage: "square.and.arrow.down") }
                if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
                Button { confirmSampleData = true } label: { Label("Load sample data", systemImage: "sparkles") }
                Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete all data", systemImage: "trash") }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Text("DayMind stores everything on this iPhone (and in your private iCloud if you turn sync on). It has no accounts, no ads, no analytics, no API keys and no paid services. Understanding uses Apple Intelligence on the device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onDisappear {
            env.persistPreferences()
            Task { await env.briefing.refreshSchedule() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task {
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let summary = try await env.exportImport.importData(data)
                    importMessage = summary.description
                } catch {
                    importMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
        .confirmationDialog("Delete everything?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all reminders, memories, projects and settings", role: .destructive) {
                Task { try? await env.deleteAllData() }
            }
        } message: {
            Text("This removes all DayMind data from this iPhone and cancels every notification. It cannot be undone. Export a backup first if you want to keep anything.")
        }
        .confirmationDialog("Load sample data?", isPresented: $confirmSampleData, titleVisibility: .visible) {
            Button("Add sample reminders and memories") { Task { await SampleData.seed(into: env) } }
        } message: {
            Text("Adds a few example reminders, memories, people and a project so you can try the app.")
        }
    }

    private func timeRow(_ label: String, _ keyPath: WritableKeyPath<TimeDefaults, TimeOfDay>) -> some View {
        DatePicker(label, selection: Binding(
            get: { date(for: settings.timeDefaults[keyPath: keyPath]) },
            set: { new in
                var d = settings.timeDefaults
                d[keyPath: keyPath] = timeOfDay(from: new)
                settings.timeDefaults = d
            }), displayedComponents: .hourAndMinute)
    }

    private var briefingDateBinding: Binding<Date> {
        Binding(get: { date(for: settings.briefingTime) }, set: { settings.briefingTime = timeOfDay(from: $0) })
    }

    private func date(for t: TimeOfDay) -> Date {
        Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
    }

    private func timeOfDay(from date: Date) -> TimeOfDay {
        TimeOfDay(hour: Calendar.current.component(.hour, from: date), minute: Calendar.current.component(.minute, from: date))
    }

    private func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}

struct TimeZonePicker: View {
    @Binding var selection: String?
    @State private var search = ""

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Button {
                selection = nil
            } label: {
                HStack { Text("Follow the iPhone (\(TimeZone.current.identifier))"); Spacer(); if selection == nil { Image(systemName: "checkmark") } }
            }
            ForEach(zones, id: \.self) { id in
                Button { selection = id } label: {
                    HStack { Text(id.replacingOccurrences(of: "_", with: " ")); Spacer(); if selection == id { Image(systemName: "checkmark") } }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Time zone")
    }
}
