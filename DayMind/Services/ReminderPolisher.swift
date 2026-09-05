import Foundation
import os
import DayMindCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional, off by default: tidies a reminder title without changing its meaning.
///
/// Two layers:
///  1. A deterministic baseline that works everywhere (capitalisation, known names, filler words).
///  2. When the setting is on *and* Apple Intelligence is available, the on-device model may rephrase
///     for clarity — but its output is validated: no new numbers, no new capitalised names, no new
///     time words, not longer than double the original. Anything else is rejected and the baseline
///     result is kept. The scheduled time is never touched. The original words stay in the transcript.
@MainActor
final class ReminderPolisher {
    private let settings: SettingsStore
    private let people: PersonService
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "Polisher")

    init(settings: SettingsStore, people: PersonService) {
        self.settings = settings
        self.people = people
    }

    // MARK: Deterministic baseline

    static let fillers: Set<String> = ["um", "uh", "like", "please", "kinda", "sorta", "basically", "just"]
    static let timeWords: Set<String> = ["today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "am", "pm", "noon", "midnight", "week", "month", "year", "urgent", "asap", "immediately", "must", "important"]

    /// Cleans a title without a model. Safe to apply always.
    static func baseline(_ title: String, knownNames: [String]) -> String {
        var words = title.split(separator: " ").map(String.init).filter { !fillers.contains($0.lowercased()) }
        guard !words.isEmpty else { return title }
        let names = Dictionary(uniqueKeysWithValues: knownNames.map { ($0.lowercased(), $0) })
        words = words.map { w in
            let stripped = w.trimmingCharacters(in: .punctuationCharacters)
            if let proper = names[stripped.lowercased()] { return w.replacingOccurrences(of: stripped, with: proper) }
            return w
        }
        var joined = words.joined(separator: " ")
        joined = joined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        joined = joined.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return SpokenFormatter.capitalizeFirst(joined)
    }

    /// Guards against the model adding meaning. Returns nil when the proposal is unacceptable.
    static func validate(original: String, proposal: String) -> String? {
        let p = proposal.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !p.isEmpty, p.count <= max(12, original.count * 2), !p.contains("\n") else { return nil }
        let digits = { (s: String) in s.filter(\.isNumber) }
        guard digits(p) == digits(original) else { return nil }  // no new amounts or dates
        let originalWords = Set(original.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        let proposalWords = p.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        for (i, w) in proposalWords.enumerated() {
            let lower = w.lowercased()
            if timeWords.contains(lower), !originalWords.contains(lower) { return nil }        // no inferred deadline/urgency
            if i > 0, w.first?.isUppercase == true, !originalWords.contains(lower), !["i"].contains(lower) { return nil } // no new people/places
        }
        return p
    }

    // MARK: Entry point

    /// Polishes `title`. Always returns something usable; falls back to the baseline or the original.
    func polish(_ title: String) async -> String {
        let names = people.all().map(\.name)
        let base = Self.baseline(title, knownNames: names)
        guard settings.polishReminders else { return base }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(model: .default) {
                    "You tidy short reminder titles. Fix grammar, capitalisation and clarity only. Never add, remove or change any person, time, date, amount, urgency or instruction. Reply with the tidied title only, no quotes."
                }
                let response = try await session.respond(to: Prompt("Title: \(base)"), options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 40))
                if let accepted = Self.validate(original: base, proposal: response.content) { return accepted }
                logger.info("Polish proposal rejected by validator")
            } catch {
                logger.error("Polish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        return base
    }
}
