import Foundation
import AVFoundation

/// Central audio-session handling for recording (transcription) and playback (spoken replies).
enum AudioSessionManager {
    static func configureForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: [])
    }

    static func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Captures microphone audio with `AVAudioEngine` and hands PCM buffers to a recognizer.
/// No audio is ever written to disk.
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "DayMind.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            bufferHandler(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
