import SwiftUI

/// The faceless butler: a cropped tuxedo torso drawn with SwiftUI shapes. The whole figure is the
/// microphone button. The gold shirt stud is the microphone and carries the state (glow, waveform,
/// progress ring, checkmark, warning).
struct ButlerFigureView: View {
    let state: VoiceState
    var size: CGFloat = 260

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var wave = false
    @State private var spin = false

    var body: some View {
        ZStack {
            torso
            shirtAndTie
            micPin
        }
        .frame(width: size, height: size * 0.92)
        .scaleEffect(breathing && state == .idle ? 1.012 : 1.0)
        .onAppear { updateAnimations() }
        .onChange(of: state) { _, _ in updateAnimations() }
        .accessibilityHidden(true) // the parent button carries the label
    }

    /// Animations run only while a state needs them, and never under Reduce Motion or UI testing,
    /// so the screen is quiet (and cheap) when nothing is happening.
    private var animationsAllowed: Bool { !reduceMotion && !LaunchOptions.isUITesting }

    private func updateAnimations() {
        guard animationsAllowed else {
            breathing = false; wave = false; spin = false
            return
        }
        switch state {
        case .idle:
            wave = false; spin = false
            if !breathing { withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathing = true } }
        case .listening:
            breathing = false; spin = false
            if !wave { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { wave = true } }
        case .processing, .saving, .requestingPermission:
            breathing = false; wave = false
            if !spin { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true } }
        default:
            withAnimation(.default) { breathing = false; wave = false; spin = false }
        }
    }

    // MARK: Torso

    private var torso: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Shoulders + jacket body (cropped at the collar, no head).
                JacketShape()
                    .fill(LinearGradient(colors: [ButlerTheme.jacketHighlight, ButlerTheme.jacket], startPoint: .top, endPoint: .bottom))
                // Lapels: two soft triangles opening into the shirt.
                LapelShape(side: .left).fill(ButlerTheme.jacketHighlight.opacity(0.9))
                LapelShape(side: .right).fill(ButlerTheme.jacketHighlight.opacity(0.9))
                // Lapel edge highlight.
                LapelShape(side: .left).stroke(ButlerTheme.gold.opacity(0.35), lineWidth: max(1, w * 0.004))
                LapelShape(side: .right).stroke(ButlerTheme.gold.opacity(0.35), lineWidth: max(1, w * 0.004))
                // Pocket square.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.20, y: h * 0.56))
                    p.addLine(to: CGPoint(x: w * 0.31, y: h * 0.545))
                    p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.60))
                    p.addLine(to: CGPoint(x: w * 0.21, y: h * 0.60))
                    p.closeSubpath()
                }
                .fill(ButlerTheme.shirt)
            }
        }
    }

    private var shirtAndTie: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ShirtShape().fill(ButlerTheme.shirt)
                // Collar points.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.40, y: h * 0.02))
                    p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.16))
                    p.addLine(to: CGPoint(x: w * 0.60, y: h * 0.02))
                    p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.02))
                    p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.11))
                    p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.02))
                    p.closeSubpath()
                }
                .fill(ButlerTheme.shirt.opacity(0.9))
                // Bow tie.
                BowTieShape()
                    .fill(ButlerTheme.bowTie)
                    .frame(width: w * 0.26, height: h * 0.11)
                    .position(x: w * 0.5, y: h * 0.145)
                Circle().fill(ButlerTheme.bowTie)
                    .frame(width: w * 0.05, height: w * 0.05)
                    .position(x: w * 0.5, y: h * 0.145)
                // Shirt studs above and below the pin.
                ForEach([0.30, 0.66, 0.78], id: \.self) { y in
                    Circle().fill(ButlerTheme.gold.opacity(0.9))
                        .frame(width: w * 0.022, height: w * 0.022)
                        .position(x: w * 0.5, y: h * CGFloat(y))
                }
            }
        }
    }

    // MARK: Mic pin (the state indicator)

    private var micPin: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pinSize = w * 0.20
            ZStack {
                if state == .listening {
                    Circle().fill(ButlerTheme.listening.opacity(0.22))
                        .frame(width: pinSize * (wave && !reduceMotion ? 1.9 : 1.5), height: pinSize * (wave && !reduceMotion ? 1.9 : 1.5))
                }
                Circle()
                    .fill(LinearGradient(colors: [ButlerTheme.gold, ButlerTheme.gold.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: pinSize, height: pinSize)
                    .overlay(Circle().strokeBorder(ButlerTheme.shirt.opacity(0.7), lineWidth: max(1, w * 0.006)))
                    .shadow(color: pinColor.opacity(state == .idle ? 0.15 : 0.45), radius: state == .idle ? 3 : 10)
                if case .processing = state {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(ButlerTheme.shirt, style: StrokeStyle(lineWidth: max(2, w * 0.012), lineCap: .round))
                        .frame(width: pinSize * 1.25, height: pinSize * 1.25)
                        .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
                } else if case .saving = state {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(ButlerTheme.shirt, style: StrokeStyle(lineWidth: max(2, w * 0.012), lineCap: .round))
                        .frame(width: pinSize * 1.25, height: pinSize * 1.25)
                        .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
                }
                Image(systemName: pinSymbol)
                    .font(.system(size: pinSize * 0.5, weight: .semibold))
                    .foregroundStyle(pinSymbolColor)
                if state == .listening {
                    WaveformView(animating: wave && !reduceMotion)
                        .frame(width: pinSize * 1.6, height: pinSize * 0.45)
                        .offset(y: pinSize * 0.95)
                }
            }
            .position(x: w * 0.5, y: h * 0.48)
        }
    }

    private var pinSymbol: String {
        switch state {
        case .idle, .requestingPermission, .processing, .saving: return "mic.fill"
        case .listening: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .success: return "checkmark"
        case .failure: return "exclamationmark"
        }
    }

    private var pinColor: Color {
        switch state {
        case .listening: return ButlerTheme.listening
        case .success: return ButlerTheme.success
        case .failure: return ButlerTheme.failure
        case .processing, .saving, .requestingPermission: return ButlerTheme.attention
        default: return ButlerTheme.gold
        }
    }

    private var pinSymbolColor: Color {
        switch state {
        case .listening: return ButlerTheme.listening
        case .success: return ButlerTheme.success
        case .failure: return ButlerTheme.failure
        default: return ButlerTheme.jacket
        }
    }
}

// MARK: - Shapes (all in unit space, scaled by the frame)

struct JacketShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        // Collar line (cropped top), sloping shoulders, straight sides, cropped bottom.
        p.move(to: CGPoint(x: w * 0.36, y: 0))
        p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.05))
        p.addQuadCurve(to: CGPoint(x: w * 0.03, y: h * 0.22), control: CGPoint(x: w * 0.12, y: h * 0.07))
        p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.40), control: CGPoint(x: 0, y: h * 0.28))
        p.addLine(to: CGPoint(x: w * 0.02, y: h))
        p.addLine(to: CGPoint(x: w * 0.98, y: h))
        p.addLine(to: CGPoint(x: w, y: h * 0.40))
        p.addQuadCurve(to: CGPoint(x: w * 0.97, y: h * 0.22), control: CGPoint(x: w, y: h * 0.28))
        p.addQuadCurve(to: CGPoint(x: w * 0.70, y: h * 0.05), control: CGPoint(x: w * 0.88, y: h * 0.07))
        p.addLine(to: CGPoint(x: w * 0.64, y: 0))
        p.closeSubpath()
        return p
    }
}

struct LapelShape: Shape {
    enum Side { case left, right }
    let side: Side
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        switch side {
        case .left:
            p.move(to: CGPoint(x: w * 0.36, y: 0))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.95))
            p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.95))
            p.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.42), control: CGPoint(x: w * 0.30, y: h * 0.72))
            p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.05))
            p.closeSubpath()
        case .right:
            p.move(to: CGPoint(x: w * 0.64, y: 0))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.95))
            p.addLine(to: CGPoint(x: w * 0.58, y: h * 0.95))
            p.addQuadCurve(to: CGPoint(x: w * 0.76, y: h * 0.42), control: CGPoint(x: w * 0.70, y: h * 0.72))
            p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.05))
            p.closeSubpath()
        }
        return p
    }
}

struct ShirtShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.38, y: 0))
        p.addLine(to: CGPoint(x: w * 0.62, y: 0))
        p.addLine(to: CGPoint(x: w * 0.60, y: h * 0.95))
        p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.95))
        p.closeSubpath()
        return p
    }
}

struct BowTieShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        // Left wing
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.5))
        p.addLine(to: CGPoint(x: 0, y: h * 0.08))
        p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.92), control: CGPoint(x: -w * 0.04, y: h * 0.5))
        p.closeSubpath()
        // Right wing
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.5))
        p.addLine(to: CGPoint(x: w, y: h * 0.08))
        p.addQuadCurve(to: CGPoint(x: w, y: h * 0.92), control: CGPoint(x: w * 1.04, y: h * 0.5))
        p.closeSubpath()
        return p
    }
}

/// Five restrained bars; heights alternate while listening.
struct WaveformView: View {
    let animating: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(ButlerTheme.listening)
                    .frame(width: 3, height: animating ? CGFloat([14, 22, 10, 20, 12][i]) : CGFloat([10, 14, 18, 12, 16][i]))
            }
        }
    }
}
