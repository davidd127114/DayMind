import Foundation
import DayMindCore

/// Whether an AI provider can be used right now, and if not, why — in words the user can act on.
enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String, suggestion: String?, canRetryLater: Bool)
    case notSupportedByThisBuild

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: return "Ready"
        case .unavailable: return "Unavailable"
        case .notSupportedByThisBuild: return "Not included"
        }
    }

    var detail: String {
        switch self {
        case .available: return "Apple Intelligence is ready on this iPhone. Requests never leave the device."
        case .unavailable(let reason, let suggestion, _): return suggestion.map { "\(reason) \($0)" } ?? reason
        case .notSupportedByThisBuild: return "This build does not include an on-device model."
        }
    }
}

struct TurnSnapshot: Equatable, Sendable {
    var role: ConversationRole
    var text: String
}

/// Everything a provider needs to interpret one utterance.
struct AssistantRequest: Sendable {
    var text: String
    var now: Date
    var calendar: Calendar
    var timeDefaults: TimeDefaults
    var focusReminder: ReminderSummary?
    var lastSavedMemory: MemorySummary?
    var recentTurns: [TurnSnapshot]
}

struct ProviderResponse: Equatable, Sendable {
    /// The provider's natural-language reply (may be empty when tools did all the work).
    var text: String
    /// Set when the provider needs one clarifying answer before acting.
    var clarificationQuestion: String?
}

/// Errors surfaced by a provider. Every case maps to an Inbox reason so no input is lost.
enum AIProcessingError: LocalizedError, Equatable {
    case modelUnavailable(String)
    case inputTooLong
    case blockedBySafetyFilter
    case unsupportedLanguage
    case busy
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): return "Apple Intelligence is unavailable: \(why)"
        case .inputTooLong: return "That was too long for the on-device model. Try a shorter request."
        case .blockedBySafetyFilter: return "Apple's on-device safety filter declined to process that request."
        case .unsupportedLanguage: return "The on-device model does not support this language yet."
        case .busy: return "The on-device model is busy. Please try again in a moment."
        case .modelFailed(let why): return "The on-device model could not process that: \(why)"
        }
    }

    var inboxReason: InboxReason {
        switch self {
        case .modelUnavailable: return .modelUnavailable
        default: return .modelFailed
        }
    }
}

/// Abstraction so another provider could be added later. Only the no-cost on-device Apple
/// provider is implemented and enabled in this version. There is deliberately no field for an
/// API key or endpoint.
@MainActor
protocol AIProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Shown in Settings so the user always knows what the provider costs and where data goes.
    var costAndPrivacyNote: String { get }
    func availability() -> AIAvailability
    /// Interprets the request, calling tools on `actions` as needed. Must not claim success for
    /// anything the tools did not do — the engine composes confirmations from the action log.
    func process(_ request: AssistantRequest, actions: AssistantActions) async throws -> ProviderResponse
    /// Optional warm-up (e.g. load the model) so the first request is fast.
    func prewarm() async
}
