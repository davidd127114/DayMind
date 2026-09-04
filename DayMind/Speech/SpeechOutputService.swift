import Foundation
import AVFoundation

/// Spoken replies with `AVSpeechSynthesizer` (Apple's built-in voices; free, offline).
@MainActor
final class SpeechOutputService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speaks `text` and returns when finished or stopped.
    func speak(_ text: String, voiceIdentifier: String?, rate: Double) async {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? AudioSessionManager.configureForPlayback()
        let utterance = AVSpeechUtterance(string: trimmed)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier) ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let minRate = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maxRate = Double(AVSpeechUtteranceMaximumSpeechRate)
        utterance.rate = Float(minRate + (maxRate - minRate) * min(max(rate, 0), 1))
        utterance.prefersAssistiveTechnologySettings = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            synthesizer.speak(utterance)
        }
        AudioSessionManager.deactivate()
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    /// Voices for the picker, current language first, best quality first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }
}
