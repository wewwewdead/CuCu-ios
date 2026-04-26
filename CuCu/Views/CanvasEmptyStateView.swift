import SwiftUI

/// First-launch / empty-canvas overlay. Sits on top of the (empty)
/// canvas surface and disappears the instant the first node lands —
/// no separate "drafts page" tutorial, no full-screen onboarding,
/// just a calm editorial nudge that points at the two affordances
/// the new user actually needs (Add Element / Use Template).
///
/// Visual recipe — same editorial-scrapbook tone as every other
/// modal in the app:
///
///   - `✦` sparkle + mono spec line (`fig. 01 — start`) so the
///     blank page reads as "page one of a notebook" rather than
///     "broken state."
///   - **Caprasimo** italic display title for the call-out, then
///     **Caveat** handwritten subtitle for the friendly prompt.
///   - `❦` fleuron divider above the two CTAs.
///   - Primary "Add Element" pill in solid ink + cream text;
///     secondary "Use Template" in cream + ink stroke.
///   - Subtle entrance: heading + buttons stagger-fade in 100ms /
///     180ms behind the page mount so it lands rather than slams.
struct CanvasEmptyStateView: View {
    let onAddElement: () -> Void
    let onUseTemplate: () -> Void
    let onPreview: () -> Void

    @State private var headingVisible = false
    @State private var bodyVisible = false
    @State private var ctasVisible = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)

            // — spec line —
            HStack(spacing: 6) {
                Text("✦")
                    .font(.cucuSerif(13, weight: .regular))
                    .foregroundStyle(Color.cucuRoseStroke)
                Text("fig. 01 — start")
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.cucuInkSoft)
            }
            .opacity(headingVisible ? 1 : 0)
            .offset(y: headingVisible ? 0 : -4)

            // — chunky cute headline —
            Text("Design your\ninternet identity.")
                .font(.custom("Caprasimo-Regular", size: 36))
                .foregroundStyle(Color.cucuInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .opacity(headingVisible ? 1 : 0)
                .offset(y: headingVisible ? 0 : 8)

            // — handwritten body —
            Text("A blank page is waiting for your story.\nAdd an element or pick a template to begin.")
                .font(.custom("Caveat-Regular", size: 21))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
                .opacity(bodyVisible ? 1 : 0)
                .offset(y: bodyVisible ? 0 : 6)

            CucuFleuronDivider()
                .frame(maxWidth: 220)
                .padding(.vertical, 4)
                .opacity(bodyVisible ? 1 : 0)

            // — CTA pair —
            VStack(spacing: 10) {
                Button(action: onAddElement) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .heavy))
                        Text("Add Element")
                            .font(.cucuSerif(16, weight: .bold))
                    }
                    .foregroundStyle(Color.cucuCard)
                    .frame(maxWidth: 240)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.cucuInk))
                }
                .buttonStyle(CucuPressableButtonStyle())

                Button(action: onUseTemplate) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Use Template")
                            .font(.cucuSerif(15, weight: .semibold))
                    }
                    .foregroundStyle(Color.cucuInk)
                    .frame(maxWidth: 240)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.cucuCard))
                    .overlay(Capsule().strokeBorder(Color.cucuInk, lineWidth: 1.2))
                }
                .buttonStyle(CucuPressableButtonStyle())

                Button(action: onPreview) {
                    Label("Preview canvas", systemImage: "eye")
                        .font(.cucuSerif(13, weight: .medium))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .opacity(ctasVisible ? 1 : 0)
            .offset(y: ctasVisible ? 0 : 10)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .background(Color.cucuPaper.opacity(0.0)) // Tap pass-through
        .allowsHitTesting(true)
        .onAppear {
            // Stagger the reveal so the page reads as "page is set
            // → headline lands → body settles → buttons arrive".
            withAnimation(.easeOut(duration: 0.45).delay(0.04)) {
                headingVisible = true
            }
            withAnimation(.easeOut(duration: 0.45).delay(0.18)) {
                bodyVisible = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.28)) {
                ctasVisible = true
            }
        }
    }
}

extension CanvasEmptyStateView: Equatable {
    /// The empty-state view's only inputs are closures, which we
    /// don't compare — they capture references that stay current.
    /// Returning `true` means SwiftUI never re-evaluates the body
    /// once the view is mounted; the staggered-reveal animations
    /// are driven by `@State` flags inside the view, which are
    /// preserved across cached renders.
    static func == (lhs: CanvasEmptyStateView, rhs: CanvasEmptyStateView) -> Bool {
        true
    }
}
