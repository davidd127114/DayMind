import Foundation
import Observation

/// Which slice of My Book is showing.
enum BookFilter: String, CaseIterable, Identifiable, Hashable {
    case all, upcoming, completed, memories, needsAttention

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        case .memories: return "Memories"
        case .needsAttention: return "Needs attention"
        }
    }
    var systemImage: String {
        switch self {
        case .all: return "book.closed"
        case .upcoming: return "clock"
        case .completed: return "checkmark.circle"
        case .memories: return "brain.head.profile"
        case .needsAttention: return "tray.full"
        }
    }
}

/// Navigation state shared by the two screens, deep links, notifications and App Intents.
@MainActor
@Observable
final class AppRouter {
    /// My Book is a pushed destination from the Butler screen.
    var showMyBook = false
    var bookFilter: BookFilter = .all
    var bookSearch = ""
    var showSettings = false
    /// Set when the Butler should begin listening as soon as it appears (Action Button, control, Siri).
    var autoStartListening = false
    /// A reminder to open for editing (from a notification tap).
    var reminderToOpen: UUID?

    func openBook(_ filter: BookFilter = .all, search: String = "") {
        bookFilter = filter
        bookSearch = search
        showMyBook = true
    }

    func openTalk(autoStart: Bool) {
        showMyBook = false
        showSettings = false
        autoStartListening = autoStart
    }

    func open(reminderID: UUID) {
        showMyBook = false
        reminderToOpen = reminderID
    }

    /// Handles `daymind://` URLs from the widget, control, shortcuts and notification "Open" action.
    /// - `daymind://talk?autostart=1`
    /// - `daymind://today` · `daymind://inbox` · `daymind://memories` · `daymind://book`
    /// - `daymind://reminder/<uuid>`
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "daymind" else { return }
        let host = url.host?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch host {
        case "talk":
            let auto = query.first(where: { $0.name == "autostart" })?.value
            openTalk(autoStart: auto == "1" || auto == "true")
        case "today", "book": openBook(.upcoming)
        case "inbox": openBook(.needsAttention)
        case "memories": openBook(.memories)
        case "projects": openBook(.all)
        case "settings": showSettings = true
        case "reminder":
            if let id = UUID(uuidString: url.lastPathComponent) { open(reminderID: id) }
        default: break
        }
    }
}
