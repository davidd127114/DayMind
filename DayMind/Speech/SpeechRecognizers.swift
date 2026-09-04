import Foundation
import AVFoundation
import Speech
import os

/// Common interface over the two Apple transcription engines. Text updates arrive on the main actor.
protocol SpeechRecognizing: AnyObject {
    var engineName: String { get }
    /// True when recognition is guaranteed to run on the device.
    var isOnDevice: Bool { get }
    func start(locale: Locale, onUpdate: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void) async throws
    /// Stops capture, finalizes recognition and returns the full transcript.
    func stop() async -> String
    func cancel()
}

enum SpeechRecognizerError: LocalizedError {
    case notAvailable
    case localeUnsupported
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Speech recognition is not available on this device."
        case .localeUnsupported: return "Speech recognition does not support your language yet."
        case .permissionDenied: return "Speech recognition permission was not granted."
        }
    }
}

// MARK: - iOS 26 SpeechAnalyzer (on-device)

@available(iOS 26.0, *)
final class AnalyzerSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    let engineName = "SpeechAnalyzer (on-device)"
    let isOnDevice = true

    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "SpeechAnalyzer")
    private let capture = AudioCaptureEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return (finalized + " " + volatile).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    func start(locale: Locale, onUpdate: @escaping @MainActor (String, Bool) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechRecognizerError.notAvailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw SpeechRecognizerError.localeUnsupported }

        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            // Downloads Apple's on-device speech model once (free; from Apple, not a third party).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        self.transcriber = transcriber
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        lock.lock(); finalized = ""; volatile = ""; lock.unlock()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.lock.lock()
                    if result.isFinal {
                        self.finalized = (self.finalized + " " + text).trimmingCharacters(in: .whitespaces)
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    self.lock.unlock()
                    let snapshot = self.transcript
                    let isFinal = result.isFinal
                    await MainActor.run { onUpdate(snapshot, isFinal) }
                }
            } catch {
                self.logger.error("Transcriber results ended with error: \(error.localizedDescription, privacy: .public)")
            }
        }

        try AudioSessionManager.configureForRecording()
        try capture.start { [weak self] buffer in self?.feed(buffer) }
        try await analyzer.start(inputSequence: stream)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let continuation = inputContinuation else { return }
        if buffer.format.sampleRate == analyzerFormat.sampleRate, buffer.format.channelCount == analyzerFormat.channelCount, buffer.format.commonFormat == analyzerFormat.commonFormat {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func stop() async -> String {
        capture.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
                logger.error("finalize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        AudioSessionManager.deactivate()
        return transcript
    }

    func cancel() {
        capture.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        transcriber = nil
        AudioSessionManager.deactivate()
    }
}

// MARK: - SFSpeechRecognizer fallback (on-device when supported, otherwise Apple's speech service)

final class LegacySpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private(set) var engineName = "Apple Speech"
    private(set) var isOnDevice = false

    private let preferOnDevice: Bool
    private let capture = AudioCaptureEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private let logger = Logger(subsystem: "com.dabkowski.DayMind", category: "SFSpeech")

    init(preferOnDevice: Bool) {
        self.preferOnDevice = preferOnDevice
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start(locale: Locale, onUpdate: @escaping @MainActor (String, Bool) -> Void) async throws {
        guard await Self.requestAuthorization() else { throw SpeechRecognizerError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechRecognizerError.notAvailable
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = preferOnDevice
            isOnDevice = preferOnDevice
            engineName = preferOnDevice ? "Apple Speech (on-device)" : "Apple Speech (Apple servers)"
        } else {
            isOnDevice = false
            engineName = "Apple Speech (Apple servers)"
        }
        self.request = request
        lock.lock(); latest = ""; lock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock(); self.latest = text; self.lock.unlock()
                let isFinal = result.isFinal
                Task { @MainActor in onUpdate(text, isFinal) }
                if isFinal { self.resumeFinal() }
            }
            if let error {
                self.logger.debug("Recognition ended: \(error.localizedDescription, privacy: .public)")
                self.resumeFinal()
            }
        }
        try AudioSessionManager.configureForRecording()
        try capture.start { [weak self] buffer in self?.request?.append(buffer) }
    }

    private func resumeFinal() {
        lock.lock()
        let c = finalContinuation
        finalContinuation = nil
        lock.unlock()
        c?.resume()
    }

    func stop() async -> String {
        capture.stop()
        request?.endAudio()
        // Wait briefly for the final result; whatever we have is returned either way.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    guard let self else { c.resume(); return }
                    self.lock.lock()
                    self.finalContinuation = c
                    self.lock.unlock()
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(2.5)) }
            await group.next()
            group.cancelAll()
        }
        resumeFinal()
        task?.cancel()
        task = nil
        request = nil
        AudioSessionManager.deactivate()
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func cancel() {
        capture.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        resumeFinal()
        AudioSessionManager.deactivate()
    }
}
