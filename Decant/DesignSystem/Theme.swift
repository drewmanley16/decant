import SwiftUI
import UIKit

/// Brand palette. Every color adapts to dark mode.
enum Palette {
    static let burgundy = dynamic(light: 0x7A1A2E, dark: 0xC9566B)
    static let burgundyDeep = dynamic(light: 0x4E0F1D, dark: 0x8E2A3E)
    static let cream = dynamic(light: 0xF9F4EC, dark: 0x161213)
    static let creamElevated = dynamic(light: 0xFFFDF8, dark: 0x221C1D)
    static let charcoal = dynamic(light: 0x24201F, dark: 0xF2ECE4)
    static let secondaryText = dynamic(light: 0x6E6460, dark: 0xA79D97)
    static let gold = dynamic(light: 0xB08D57, dark: 0xD4B27A)
    static let hairline = dynamic(light: 0xE7DED2, dark: 0x352D2D)
    static let success = dynamic(light: 0x3E7B4F, dark: 0x6FBF84)
    static let warning = dynamic(light: 0xB7791F, dark: 0xE0A84E)

    static func wineColor(_ type: WineType) -> Color {
        Color(uiColor: wineUIColor(type))
    }

    /// Glass tint per wine type; shared with the 3D cellar.
    static func wineUIColor(_ type: WineType) -> UIColor {
        switch type {
        case .red: UIColor(hex: 0x3A0E16)
        case .white: UIColor(hex: 0x8C9A5B)
        case .rose: UIColor(hex: 0xE59AA2)
        case .sparkling: UIColor(hex: 0x2F3B26)
        case .dessert: UIColor(hex: 0xC99A3B)
        case .fortified: UIColor(hex: 0x4A1C10)
        case .orange: UIColor(hex: 0xC4712E)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Typography: New York (serif) for display, SF for UI. All styles scale with Dynamic Type.
enum Typo {
    static let hero = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let title = Font.system(.title, design: .serif).weight(.semibold)
    static let title2 = Font.system(.title2, design: .serif).weight(.semibold)
    static let title3 = Font.system(.title3, design: .serif).weight(.medium)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let eyebrow = Font.caption.weight(.semibold)
}

enum Metrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 24
    static let smallRadius: CGFloat = 14
}

extension View {
    /// Large rounded surface used for cards throughout the app.
    func cardSurface(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background {
                // Shadow only the card shape, not the text inside it.
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Palette.creamElevated)
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
    }

    func eyebrow() -> some View {
        self.font(Typo.eyebrow)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Palette.gold)
    }

    /// Cream background for Form/List screens instead of system grouped gray.
    func brandedForm() -> some View {
        self.scrollContentBackground(.hidden).background(Palette.cream.ignoresSafeArea())
    }

    func screenBackground() -> some View {
        self.background(Palette.cream.ignoresSafeArea())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Palette.burgundy

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Palette.burgundy)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.burgundy.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.burgundy.opacity(0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
