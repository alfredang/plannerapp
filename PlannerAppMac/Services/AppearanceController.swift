import AppKit
import SwiftUI

/// The desktop app's appearance choice (the iPhone app is light-themed by design).
/// Stored as a raw string in `appearanceMode` AppStorage — this is the *default* the app
/// starts in; the toolbar toggle can flip Light/Dark for the current session on top of it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` means "follow the system appearance".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// The saved default (Settings ▸ Appearance).
    static var savedDefault: AppearanceMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceMode.init) ?? .system
    }
}

/// Applies the appearance app-wide through `NSApp.appearance`, so every window — the main
/// window, the Settings window, sheets and the sidebar material — switches together.
/// (`.preferredColorScheme(nil)` does not reliably hand a window back to the system
/// appearance on macOS once it has been forced, which is why this goes through AppKit.)
@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    /// Session-only Light/Dark flip from the toolbar / View menu. Not persisted: the next
    /// launch starts in the saved default again. Cleared when the default is changed.
    @Published private(set) var sessionOverride: AppearanceMode?

    private init() {}

    /// The mode currently in force.
    var current: AppearanceMode { sessionOverride ?? AppearanceMode.savedDefault }

    /// Whether the app is currently drawing dark, resolving "System" against the Mac.
    var isDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func apply() {
        NSApp?.appearance = current.nsAppearance
    }

    /// Flip between Light and Dark for this session.
    func toggle() {
        sessionOverride = isDark ? .light : .dark
        apply()
    }

    /// The saved default changed in Settings — it takes effect immediately.
    func defaultDidChange() {
        sessionOverride = nil
        apply()
    }
}
