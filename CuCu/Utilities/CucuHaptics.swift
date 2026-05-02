import UIKit

/// Tiny wrapper around UIKit's haptic generators so call sites stay
/// expressive (`CucuHaptics.success()`) instead of repeating the
/// `prepare()` + `notificationOccurred(_:)` boilerplate everywhere.
///
/// Why this matters for a "polish pass" — haptics are the kind of
/// thing that escapes review when each site builds its own
/// `UIImpactFeedbackGenerator`. Centralising them means the team can
/// later audit / disable / re-tune all feedback in one place, and we
/// avoid the common bug where two consecutive calls to the same
/// action generate two pulses on rapid taps.
enum CucuHaptics {
    /// Light tap — used for "thing was selected" / inert acknowledgements.
    static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    /// Medium impact — used for "thing was duplicated / copied".
    /// Distinct from `selection()` so the user can tell a duplicate
    /// happened versus just a tap.
    static func duplicate() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        g.impactOccurred()
    }

    /// Warning notification — used for destructive actions
    /// (delete). The OS plays a triple-pulse the user recognises
    /// from system "are you sure?" affordances.
    static func delete() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }

    /// Success notification — used for "publish succeeded",
    /// "template applied", and similar happy-path completions.
    /// Single rising tone the OS reserves for victory moments.
    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    /// Soft impact — used when a node is added (the user just
    /// dropped something onto the canvas) or an inspector opens.
    /// Quieter than `duplicate()` so frequent actions don't feel
    /// loud.
    static func soft() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        g.impactOccurred()
    }
}
