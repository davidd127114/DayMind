import Foundation
import AVFoundation
import Observation
import os
import DayMindCore

/// Every visible state of the Talk screen.
enum VoiceState: Equatable {
    case idle
    case requestingPermission
    case listening
    case processing
    case saving
    case speaking
    case success
    case failure(String)

    var label: String {
        switch self {
        case .idle: return "Tap to talk"
        case .requestingPermission: return "Asking for permission…"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .saving: return "Saving…"
        case .speaking: return "Speaking…"
        case .success: return "Done"
        case .failure(let message): return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .listening, .processing, .saving, .speaking, .requestingPermission: return true
        default: return false
        }
    }
}

/// Coordinates microphone capture, transcription and spoken output for the Talk screen.
@MainActor
@Observable
final class VoiceController {
    private(set) var state: VoiceState = .idle
    private(set) var liveTranscript = ""
    private(set) var engineName = "—"
    private(set) var isOnDeviceRecognition: Bool?
    private(set) var microphonePermission: AVAudioApplication.recordPermission = .undetermined

    private let settings: SettingsStore
    private let output = SpeechOutputService()
    private var recognizer: (any SpeechRecognizing)?
    private var interruptionObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "Voice")

    /// Called when listening was interrupted (phone call, Siri) so the caller can preserve the transcript.
    var onInterrupted: ((String) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        microphonePermission = AVAudioApplication.shared.recordPermission
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    var recognitionDisclosure: String {
        switch isOnDeviceRecognition {
        case .some(true): return "Speech is transcribed on this iPhone. Audio never leaves the device."
        case .some(false): return "This iPhone does not support on-device recognition for your language, so audio is transcribed by Apple's speech service (operated by Apple, no third-party or paid API)."
        case .none: return "Recognition engine is chosen when you first tap the microphone."
        }
    }

    // MARK: Listening

    func startListening() async {
        guard !state.isBusy else { return }
        liveTranscript = ""
        state = .requestingPermission
        let granted = await AVAudioApplication.requestRecordPermission()
        microphonePermission = AVAudioApplication.shared.recordPermission
        guard granted else {
            state = .failure("Microphone access is off. Enable it in Settings → Privacy & Security → Microphone.")
            return
        }
        output.stop()
        let recognizer = makeRecognizer()
        self.recognizer = recognizer
        do {
            try await recognizer.start(locale: .current) { [weak self] text, _ in
                guard let self, self.state == .listening else { return }
                self.liveTranscript = text
            }
            engineName = recognizer.engineName
            isOnDeviceRecognition = recognizer.isOnDevice
            state = .listening
        } catch {
            logger.error("Could not start recognizer: \(error.localizedDescription, privacy: .public)")
            if #available(iOS 26.0, *), recognizer is AnalyzerSpeechRecognizer {
                // Fall back to the classic recognizer once, then report.
                let legacy = LegacySpeechRecognizer(preferOnDevice: settings.preferOnDeviceSpeech)
                self.recognizer = legacy
                do {
                    try await legacy.start(locale: .current) { [weak self] text, _ in
                        guard let self, self.state == .listening else { return }
                        self.liveTranscript = text
                    }
                    engineName = legacy.engineName
                    isOnDeviceRecognition = legacy.isOnDevice
                    state = .listening
                    return
                } catch {
                    state = .failure(error.localizedDescription)
                    return
                }
            }
            state = .failure(error.localizedDescription)
        }
    }

    /// Stops listening and returns what was heard (may be empty).
    func stopListening() async -> String {
        guard state == .listening, let recognizer else { return liveTranscript }
        state = .processing
        let text = await recognizer.stop()
        self.recognizer = nil
        let final = text.isEmpty ? liveTranscript : text
        liveTranscript = final
        return final
    }

    func cancelListening() {
        recognizer?.cancel()
        recognizer = nil
        liveTranscript = ""
        state = .idle
    }

    // MARK: State driven by the Talk screen

    func setProcessing() { state = .processing }
    func setSaving() { state = .saving }
    func setSuccess() { state = .success }
    func setFailure(_ message: String) { state = .failure(message) }
    func setIdle() { state = .idle }

    // MARK: Speaking

    func speak(_ text: String) async {
        guard settings.speakResponses else { return }
        state = .speaking
        await output.speak(text, voiceIdentifier: settings.voiceIdentifier, rate: settings.speechRate)
        if state == .speaking { state = .idle }
    }

    func stopSpeaking() {
        output.stop()
        if state == .speaking { state = .idle }
    }

    func stopEverything(reason: String) {
        if state == .listening, !liveTranscript.isEmpty { onInterrupted?(liveTranscript) }
        recognizer?.cancel()
        recognizer = nil
        output.stop()
        state = .idle
    }

    // MARK: Helpers

    private func makeRecognizer() -> any SpeechRecognizing {
        if #available(iOS 26.0, *), settings.preferOnDeviceSpeech, AnalyzerSpeechRecognizer.isSupported {
            return AnalyzerSpeechRecognizer()
        }
        return LegacySpeechRecognizer(preferOnDevice: settings.preferOnDeviceSpeech)
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if state == .listening {
                let text = liveTranscript
                recognizer?.cancel()
                recognizer = nil
                state = .failure("Listening was interrupted.")
                if !text.isEmpty { onInterrupted?(text) }
            } else if state == .speaking {
                output.stop()
                state = .idle
            }
        case .ended:
            break
        @unknown default:
            break
        }
    }
}
