import Foundation
import Observation

/// Navigation state shared by the tab bar, deep links, notifications and App Intents.
@MainActor
@Observable
final class AppRouter {
    enum Tab: String, Hashable, CaseIterable {
        case today, talk, memories, projects, inbox
    }

    var selectedTab: Tab = .today
    /// Set when the Talk screen should begin listening as soon as it appears (Action Button, control, Siri).
    var autoStartListening = false
    /// A reminder to open (from a notification tap).
    var reminderToOpen: UUID?
    var showSettings = false

    func openTalk(autoStart: Bool) {
        selectedTab = .talk
        autoStartListening = autoStart
    }

    func open(reminderID: UUID) {
        selectedTab = .today
        reminderToOpen = reminderID
    }

    /// Handles `daymind://` URLs from the widget, control, shortcuts and notification "Open" action.
    /// - `daymind://talk?autostart=1`
    /// - `daymind://today`
    /// - `daymind://inbox`
    /// - `daymind://reminder/<uuid>`
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "daymind" else { return }
        let host = url.host?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch host {
        case "talk":
            let auto = query.first(where: { $0.name == "autostart" })?.value
            openTalk(autoStart: auto == "1" || auto == "true")
        case "today": selectedTab = .today
        case "inbox": selectedTab = .inbox
        case "memories": selectedTab = .memories
        case "projects": selectedTab = .projects
        case "settings": showSettings = true
        case "reminder":
            if let id = UUID(uuidString: url.lastPathComponent) { open(reminderID: id) }
        default: break
        }
    }
}
