import SwiftUI
import UIKit

/// The butler's visual identity: warm ivory with restrained champagne gold in light mode,
/// deep charcoal with the same gold in dark mode. All colours are dynamic so contrast holds in both.
enum ButlerTheme {
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light })
    }

    /// Page background.
    static let ivory = dynamic(light: UIColor(red: 0.973, green: 0.957, blue: 0.918, alpha: 1),   // #F8F4EA
                               dark: UIColor(red: 0.102, green: 0.106, blue: 0.125, alpha: 1))    // #1A1B20
    /// Cards and sheets.
    static let card = dynamic(light: UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1),
                              dark: UIColor(red: 0.145, green: 0.153, blue: 0.180, alpha: 1))
    /// Primary text.
    static let ink = dynamic(light: UIColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1),
                             dark: UIColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1))
    /// Secondary text — kept dark enough for 4.5:1 on ivory.
    static let inkSecondary = dynamic(light: UIColor(red: 0.36, green: 0.34, blue: 0.31, alpha: 1),
                                      dark: UIColor(red: 0.72, green: 0.70, blue: 0.66, alpha: 1))
    /// Champagne gold accent. Used for outlines, the mic pin and small highlights, never for body text on ivory.
    static let gold = dynamic(light: UIColor(red: 0.70, green: 0.56, blue: 0.27, alpha: 1),     // #B38F45 (readable on ivory)
                              dark: UIColor(red: 0.85, green: 0.72, blue: 0.42, alpha: 1))       // #D9B86B
    static let goldSoft = dynamic(light: UIColor(red: 0.91, green: 0.85, blue: 0.70, alpha: 1),
                                  dark: UIColor(red: 0.35, green: 0.30, blue: 0.18, alpha: 1))
    /// Jacket colours.
    static let jacket = dynamic(light: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                                dark: UIColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1))
    static let jacketHighlight = dynamic(light: UIColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1),
                                         dark: UIColor(red: 0.26, green: 0.26, blue: 0.30, alpha: 1))
    static let shirt = dynamic(light: UIColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 1),
                               dark: UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1))
    static let bowTie = dynamic(light: UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                                dark: UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1))
    /// State colours (always paired with an icon or text; never colour alone).
    static let listening = Color(red: 0.80, green: 0.30, blue: 0.28)
    static let success = Color(red: 0.22, green: 0.55, blue: 0.35)
    static let attention = Color(red: 0.78, green: 0.50, blue: 0.14)
    static let failure = Color(red: 0.72, green: 0.22, blue: 0.22)
}

extension View {
    /// Card surface used across the butler screens.
    func butlerCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(ButlerTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ButlerTheme.goldSoft, lineWidth: 1))
    }
}

/// Small capsule tag used for people, projects and categories.
struct TagView: View {
    let text: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ButlerTheme.goldSoft.opacity(0.6), in: Capsule())
        .foregroundStyle(ButlerTheme.ink)
    }
}
