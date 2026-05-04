import SwiftUI

/// Inline confirmation toast — used for moderation success
/// messages ("Reported. Thanks…", "Blocked @user", "Report
/// dismissed") that don't justify a full alert.
///
/// Bind a `String?` to the `message` parameter; when non-nil, the
/// toast slides in from the top, lingers for ~2.6s, then clears
/// the binding to nil. Multiple sequential messages stack
/// gracefully because the modifier reads off the binding's
/// transition value.
extension View {
    func cucuToast(message: Binding<String?>) -> some View {
        modifier(CucuToastModifier(message: message))
    }
}

private struct CucuToastModifier: ViewModifier {
    @Binding var message: String?
    /// One-shot timer; reset on each new message so a quick second
    /// message doesn't dismiss the first one prematurely.
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    toastCapsule(message)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .zIndex(20)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: message)
            .onChange(of: message) { _, newValue in
                dismissTask?.cancel()
                guard newValue != nil else { return }
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    if !Task.isCancelled { message = nil }
                }
            }
    }

    private func toastCapsule(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.cucuInkRule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
