import SwiftUI

/// Central design tokens. Reference these everywhere instead of raw `Color` literals so
/// dark mode is handled automatically by the asset-catalog Light/Dark variants.
enum Theme {
    /// The accent the user picked (Settings ▸ Appearance on iPhone). Read live, so the root
    /// view rebuilds its tree when the choice changes (see `MainTabView`).
    static var accent: Color { AccentTheme.current.color }
    static let card   = Color("Card")
    static let bg     = Color("Background")

    /// Standard rounded surface used for grouped cards.
    static let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    static let rowShape  = RoundedRectangle(cornerRadius: 14, style: .continuous)
}

/// Accent colour choices. `indigo` is the original asset-catalog colour (with its tuned
/// dark-mode variant); the rest are system colours, which adapt to dark mode themselves.
enum AccentTheme: String, CaseIterable, Identifiable {
    case indigo, red, blue, green, orange, purple, pink, teal

    static let storageKey = "accentTheme"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .indigo: return Color("AccentColor")
        case .red:    return .red
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        }
    }

    static var current: AccentTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AccentTheme.init) ?? .indigo
    }
}

/// Light / Dark / System choice for the iPhone app. Light is the default (the app's
/// original look); System follows the phone's setting.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "iosAppearance"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension View {
    /// Wraps content in the house-style grouped card surface.
    func cardSurface(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: Theme.cardShape)
    }
}
