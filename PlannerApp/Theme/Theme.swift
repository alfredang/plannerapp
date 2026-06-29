import SwiftUI

/// Central design tokens. Reference these everywhere instead of raw `Color` literals so
/// dark mode is handled automatically by the asset-catalog Light/Dark variants.
enum Theme {
    static let accent = Color("AccentColor")
    static let card   = Color("Card")
    static let bg     = Color("Background")

    /// Standard rounded surface used for grouped cards.
    static let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    static let rowShape  = RoundedRectangle(cornerRadius: 14, style: .continuous)
}

extension View {
    /// Wraps content in the house-style grouped card surface.
    func cardSurface(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: Theme.cardShape)
    }
}
