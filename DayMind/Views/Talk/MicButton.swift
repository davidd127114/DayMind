import SwiftUI

/// Large, one-handed microphone button with clear state colours. Tap to start, tap again to stop.
struct MicButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let state: VoiceState
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if state == .listening && !reduceMotion {
                    Circle().fill(color.opacity(0.25))
                        .frame(width: 112, height: 112)
                        .scaleEffect(pulse ? 1.25 : 0.95)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                }
                Circle().fill(color)
                    .frame(width: 88, height: 88)
                    .shadow(color: color.opacity(0.35), radius: 8, y: 4)
                Group {
                    switch state {
                    case .processing, .saving, .requestingPermission:
                        ProgressView().tint(.white).controlSize(.large)
                    case .speaking:
                        Image(systemName: "speaker.wave.2.fill")
                    case .listening:
                        Image(systemName: "stop.fill")
                    case .success:
                        Image(systemName: "checkmark")
                    case .failure:
                        Image(systemName: "exclamationmark")
                    case .idle:
                        Image(systemName: "mic.fill")
                    }
                }
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            }
            .frame(width: 120, height: 120)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(state == .listening ? "Double tap to stop and process" : "Double tap to start listening")
        .accessibilityAddTraits(.startsMediaSession)
    }

    private var color: Color {
        switch state {
        case .idle: return .accentColor
        case .listening: return .red
        case .processing, .saving, .requestingPermission: return .orange
        case .speaking: return .indigo
        case .success: return .green
        case .failure: return contrast == .increased ? .red : .pink
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Start listening"
        case .listening: return "Stop listening"
        case .processing: return "Processing"
        case .saving: return "Saving"
        case .speaking: return "Speaking. Double tap to stop"
        case .success: return "Done. Start listening"
        case .failure: return "Something went wrong. Start listening again"
        case .requestingPermission: return "Requesting microphone permission"
        }
    }
}
