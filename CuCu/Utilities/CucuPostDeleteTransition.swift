import SwiftUI

/// "Duolingo pop" removal transition for post cards.
///
/// Two-phase delete feel:
///   1. The card briefly scales up (~1.06) — anticipation, driven by
///      a `poppingPostId` flag the host list flips on the row about
///      to be deleted.
///   2. A spring-driven removal squishes the card down and fades it
///      out while the surrounding rows close the gap underneath.
///
/// Phase 1 lives on the host (a `.scaleEffect` keyed by post id).
/// Phase 2 is this transition — applied to the row itself so SwiftUI
/// owns the lifecycle when the row leaves the `ForEach`.
struct CucuPostPopRemoval: ViewModifier {
    /// 0 = identity (visible), 1 = fully removed.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1.0 - progress * 0.55, anchor: .center)
            .opacity(1.0 - progress)
            .blur(radius: progress * 3)
    }
}

extension AnyTransition {
    /// Insertion: the existing top-edge slide + fade so freshly
    /// composed posts still drop in from above.
    /// Removal: the squish-and-fade pop above, with the spring driven
    /// by the caller's `withAnimation` so the curve can be tuned per
    /// surface.
    static var cucuPostPop: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .modifier(
                active: CucuPostPopRemoval(progress: 1),
                identity: CucuPostPopRemoval(progress: 0)
            )
        )
    }
}
