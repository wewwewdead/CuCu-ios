import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide source of truth for the current `AppChromeTheme`.
/// Any view that paints page chrome (Feed, Thread, Explore, the
/// TabView shell, the picker sheet) reads from `shared` so a tap on
/// one tile repaints every visible surface in lock-step — the user
/// shouldn't see Feed update first and Explore catch up only after
/// the next swap.
///
/// Persisted via `UserDefaults` rather than `@AppStorage` directly so
/// the store can intercept writes (haptic, telemetry hook later) and
/// so callers can `@Bindable` it for the picker without going through
/// SwiftUI's property-wrapper indirection. The chosen id survives
/// app relaunches and reinstalls within the same backup chain.
@MainActor
@Observable
final class AppChromeStore {
    static let shared = AppChromeStore()

    /// `UserDefaults` key. Namespaced like the rest of the app's
    /// persisted preferences (`cucu.*`) so a defaults dump groups
    /// chrome state next to the selected tab and the theme-default
    /// font face.
    private static let storageKey = "cucu.app_chrome_theme"

    /// Currently selected preset. Reading triggers SwiftUI's
    /// observation tracking so any view that touches `theme` will
    /// rebuild when `setTheme` is called elsewhere.
    private(set) var theme: AppChromeTheme

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
            ?? AppChromeTheme.snow.id
        self.theme = AppChromeTheme.preset(for: stored)
    }

    /// Apply a theme by id. No-ops on the current selection so a
    /// repeat tap on the active tile doesn't fire the haptic twice or
    /// invalidate observers unnecessarily.
    func setTheme(_ id: String) {
        guard id != theme.id else { return }
        theme = AppChromeTheme.preset(for: id)
        UserDefaults.standard.set(theme.id, forKey: Self.storageKey)
        #if canImport(UIKit)
        // Soft impact, not selection — selection's tick is too sharp
        // for a bg repaint, soft impact reads as "the room shifted".
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }
}
