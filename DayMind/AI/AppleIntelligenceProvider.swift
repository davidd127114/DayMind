import Foundation
import os
import DayMindCore

#if canImport(FoundationModels)
import FoundationModels

/// Stage-1 structured output: a coarse classification the model fills in before tools are offered.
@available(iOS 26.0, *)
@Generable(description: "Classification of what the user wants DayMind to do")
struct IntentClassification {
    @Generable(description: "The kind of request")
    enum Kind {
        case createReminder
        case modifyReminder
        case queryReminders
        case saveMemory
        case queryMemories
        case projectAction
        case dailyBriefing
        case mixed
        case conversation
    }

    @Guide(description: "createReminder = something to do at a time/date/repeat; modifyReminder = move, snooze, complete or delete an existing reminder; queryReminders = what is due/forgotten; saveMemory = a fact or preference to remember permanently; queryMemories = recall something saved; projectAction = create a project or file something under one; dailyBriefing = ask for the briefing; mixed = both a memory and a reminder; conversation = small talk or a question needing no storage.")
    var kind: Kind

    @Guide(description: "true only when the request truly cannot be acted on without one short question (for example the only time given is 'later').")
    var needsClarification: Bool

    @Guide(description: "The one short question to ask the user, or empty string.")
    var clarificationQuestion: String
}

@available(iOS 26.0, *)
extension IntentClassification.Kind {
    var intentKind: IntentKind {
        switch self {
        case .createReminder: return .createReminder
        case .modifyReminder: return .modifyReminder
        case .queryReminders: return .queryReminders
        case .saveMemory: return .saveMemory
        case .queryMemories: return .queryMemories
        case .projectAction: return .projectAction
        case .dailyBriefing: return .dailyBriefing
        case .mixed: return .mixed
        case .conversation: return .conversation
        }
    }
}

/// The no-cost, on-device provider built on Apple's Foundation Models framework.
/// Requires an Apple Intelligence-capable iPhone running iOS 26 with Apple Intelligence enabled.
@available(iOS 26.0, *)
@MainActor
final class AppleIntelligenceProvider: AIProvider {
    let id = "apple.foundation-models"
    let displayName = "Apple Intelligence (on-device)"
    let costAndPrivacyNote = "Free. Runs entirely on this iPhone using Apple's built-in model. Nothing is sent to DayMind's developer or any third-party AI service."

    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "AppleIntelligence")
    private var prewarmed = false

    func availability() -> AIAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return Self.map(reason)
        }
    }

    static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> AIAvailability {
        switch reason {
        case .deviceNotEligible:
            return .unavailable(reason: "This iPhone does not support Apple Intelligence.",
                                suggestion: "Reminders, notes and search still work; the manual form replaces voice understanding.", canRetryLater: false)
        case .appleIntelligenceNotEnabled:
            return .unavailable(reason: "Apple Intelligence is turned off.",
                                suggestion: "Turn it on in Settings → Apple Intelligence & Siri, then come back.", canRetryLater: true)
        case .modelNotReady:
            return .unavailable(reason: "The Apple Intelligence model is still downloading or preparing.",
                                suggestion: "Keep the iPhone on Wi-Fi and charging, then try again in a few minutes.", canRetryLater: true)
        @unknown default:
            return .unavailable(reason: "Apple Intelligence is temporarily unavailable.", suggestion: "Try again later.", canRetryLater: true)
        }
    }

    func prewarm() async {
        guard !prewarmed, availability().isAvailable else { return }
        prewarmed = true
        let session = LanguageModelSession(model: .default) { "You are DayMind." }
        session.prewarm(promptPrefix: nil)
    }

    func process(_ request: AssistantRequest, actions: AssistantActions) async throws -> ProviderResponse {
        guard availability().isAvailable else {
            throw AIProcessingError.modelUnavailable(availability().detail)
        }
        let model = SystemLanguageModel.default
        let options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 500)

        do {
            // Stage 1: classify the request so the tool set offered in stage 2 stays small.
            let classifier = LanguageModelSession(model: model) { Self.classifierInstructions(request) }
            let classification = try await classifier.respond(to: Prompt(request.text), generating: IntentClassification.self, options: options).content
            let kind = classification.kind.intentKind
            logger.debug("Classified as \(kind.rawValue, privacy: .public)")

            if classification.needsClarification, kind != .queryReminders, kind != .queryMemories, kind != .dailyBriefing {
                let question = classification.clarificationQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !question.isEmpty {
                    return ProviderResponse(text: question, clarificationQuestion: question)
                }
            }

            // Stage 2: let the model call typed tools.
            let tools = ToolCatalog.tools(for: kind, actions: actions)
            let session = LanguageModelSession(model: model, tools: tools) { Self.assistantInstructions(request, intent: kind) }
            let response = try await session.respond(to: Prompt(request.text), options: options)
            return ProviderResponse(text: response.content.trimmingCharacters(in: .whitespacesAndNewlines), clarificationQuestion: nil)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch let error as LanguageModelSession.ToolCallError {
            logger.error("Tool \(error.tool.name, privacy: .public) failed: \(error.underlyingError.localizedDescription, privacy: .public)")
            throw AIProcessingError.modelFailed("the \(error.tool.name) step failed")
        } catch let error as AIProcessingError {
            throw error
        } catch {
            logger.error("Unexpected model error: \(error.localizedDescription, privacy: .public)")
            throw AIProcessingError.modelFailed(error.localizedDescription)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> AIProcessingError {
        switch error {
        case .exceededContextWindowSize: return .inputTooLong
        case .guardrailViolation: return .blockedBySafetyFilter
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .assetsUnavailable: return .modelUnavailable("the model assets are not available right now")
        case .rateLimited, .concurrentRequests: return .busy
        case .refusal: return .blockedBySafetyFilter
        case .decodingFailure: return .modelFailed("the response could not be decoded")
        case .unsupportedGuide: return .modelFailed("an unsupported generation guide was used")
        @unknown default: return .modelFailed(error.localizedDescription)
        }
    }

    // MARK: Instructions

    static func contextBlock(_ request: AssistantRequest) -> String {
        let f = DateFormatter()
        f.calendar = request.calendar
        f.timeZone = request.calendar.timeZone
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var lines = ["Current date and time: \(f.string(from: request.now)) (\(request.calendar.timeZone.identifier))."]
        if let focus = request.focusReminder {
            lines.append("The reminder most recently discussed (\"that\", \"it\", \"this\") is: \"\(focus.title)\"" + (focus.dueDate.map { " due \(SpokenFormatter.dateTimePhrase($0, now: request.now, calendar: request.calendar))" } ?? "") + ".")
        }
        if let memory = request.lastSavedMemory {
            lines.append("The most recently saved memory is: \"\(memory.title)\".")
        }
        if !request.recentTurns.isEmpty {
            lines.append("Recent conversation:")
            for turn in request.recentTurns.suffix(6) {
                lines.append("\(turn.role == .user ? "User" : "DayMind"): \(turn.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func classifierInstructions(_ request: AssistantRequest) -> String {
        """
        You classify requests for DayMind, a personal reminder and memory assistant.
        \(contextBlock(request))
        Rules:
        - "Remind me …", "every Monday …", "don't forget to …" → createReminder.
        - "Remember that …", preferences, facts about people, decisions, ideas → saveMemory.
        - A fact plus a reminder in one sentence → mixed.
        - "What did I tell you about …" → queryMemories.
        - "What do I need to do today", "what am I forgetting", "what did I forget yesterday" → queryReminders.
        - "Move/change/snooze/complete/delete … reminder" → modifyReminder.
        - "Save this under the … project" → projectAction.
        - Only set needsClarification when a required detail is missing and vague ("later", "sometime"). "Tomorrow at 3" is clear.
        """
    }

    static func assistantInstructions(_ request: AssistantRequest, intent: IntentKind) -> String {
        """
        You are DayMind, a private assistant that manages reminders and long-term memories on the user's iPhone.
        \(contextBlock(request))

        How to act:
        - Use the tools to do what the user asked. Pass dates, times and repeat patterns as the exact words the user said; the app converts them to real dates.
        - A reminder is an action tied to a time, date, repeat or condition. A memory is a fact, preference, decision or detail to keep permanently. Save both when the sentence contains both.
        - For "that", "it" or "this", pass "that" as the reminder query.
        - Never say something was saved, changed or deleted unless a tool returned success. If a tool reports a failure, tell the user it was not saved.
        - If a tool says the user is being asked to confirm or choose, do not repeat the action; reply with one short sentence acknowledging that.
        - Bulk deletion always requires the user's confirmation through the app.
        - After acting, reply in at most two short sentences. Do not list tool names.
        - Ask at most one short question, and only when the request is genuinely ambiguous.
        """
    }
}
#endif
