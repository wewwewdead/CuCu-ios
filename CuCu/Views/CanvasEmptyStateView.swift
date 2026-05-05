import SwiftUI

/// First-launch / empty-canvas overlay. Sits on top of the (empty)
/// canvas surface and disappears the instant the first node lands.
struct CanvasEmptyStateView: View {
    let onAddElement: () -> Void
    let onPreview: () -> Void

    @State private var headingVisible = false
    @State private var bodyVisible = false
    @State private var ctasVisible = false

    @Environment(\.cucuWidthClass) private var widthClass
    @State private var chrome = AppChromeStore.shared

    /// CTA buttons grow with the width class instead of capping at
    /// 240pt on every device — Pro Max / iPad have plenty of room.
    private var ctaMaxWidth: CGFloat {
        switch widthClass {
        case .compact:  return 260
        case .regular:  return 280
        case .expanded: return 320
        case .iPad:     return 360
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)

            Text("Design your\ninternet identity.")
                .font(.cucuSans(34, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .opacity(headingVisible ? 1 : 0)
                .offset(y: headingVisible ? 0 : 8)

            Text("A blank page is waiting for your story.\nAdd an element to begin.")
                .font(.cucuSans(15, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
                .opacity(bodyVisible ? 1 : 0)
                .offset(y: bodyVisible ? 0 : 6)

            VStack(spacing: 10) {
                Button(action: onAddElement) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .heavy))
                        Text("Add Element")
                            .font(.cucuSans(16, weight: .bold))
                    }
                    .foregroundStyle(chrome.theme.pageColor)
                    .frame(maxWidth: ctaMaxWidth)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(chrome.theme.inkPrimary))
                }
                .buttonStyle(CucuPressableButtonStyle())

                Button(action: onPreview) {
                    Label("Preview canvas", systemImage: "eye")
                        .font(.cucuSans(13, weight: .medium))
                        .foregroundStyle(chrome.theme.inkFaded)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.top, 12)
            .opacity(ctasVisible ? 1 : 0)
            .offset(y: ctasVisible ? 0 : 10)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
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
