import SwiftUI

/// First-run "pick a vibe" surface that replaces the bare empty
/// canvas for users who haven't picked a template yet. Fully local —
/// no network, no auth gate. Choosing a template seeds a structured
/// `ProfileDocument` and persists the choice flag so the picker never
/// fights an existing in-progress draft.
///
/// The picker is intentionally not a sheet. Mounting it inline on top
/// of the editor (the same place `CanvasEmptyStateView` lives) keeps
/// the user in the Build tab's context — picking a template feels
/// like the page filling in, not a modal-then-modal-then-canvas
/// hop. The canvas chrome behind it (`CanvasEditorView`) is
/// allowsHitTesting(false) gated by the same `canvasIsEmpty` check
/// that hid the empty-state CTAs before.
struct TemplatePickerView: View {
    /// User picked a template. Caller swaps the in-memory document,
    /// persists the new draft JSON, and flips the
    /// `cucu.hasPickedTemplate` flag.
    let onPick: (ProfileTemplate) -> Void

    /// User skipped the picker — wants to start from the blank
    /// structured profile they would have seen pre-onboarding. Caller
    /// flips the same flag so the picker doesn't re-appear next
    /// launch (a user who explicitly skipped shouldn't be re-asked).
    let onSkip: () -> Void

    @State private var headerVisible = false
    @State private var subheadVisible = false
    @State private var cardsVisible = false
    @State private var skipVisible = false

    @State private var pressed: ProfileTemplate?

    @Environment(\.cucuWidthClass) private var widthClass

    private var columnCount: Int {
        switch widthClass {
        case .compact:  return 2
        case .regular:  return 2
        case .expanded: return 3
        case .iPad:     return 3
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    subheader
                    grid
                    skipButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45).delay(0.04)) { headerVisible = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.16)) { subheadVisible = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.26)) { cardsVisible = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.42)) { skipVisible = true }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("PICK A VIBE")
                .font(.cucuMono(11, weight: .medium))
                .tracking(3.4)
                .foregroundStyle(Color.cucuInkFaded)

            Text("Where will\nyour CuCu live?")
                .font(.cucuSerif(34, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .opacity(headerVisible ? 1 : 0)
        .offset(y: headerVisible ? 0 : 8)
    }

    private var subheader: some View {
        Text("Pick a starting point. You can change everything after.")
            .font(.cucuEditorial(14, italic: true))
            .foregroundStyle(Color.cucuInkSoft)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
            .opacity(subheadVisible ? 1 : 0)
            .offset(y: subheadVisible ? 0 : 6)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(ProfileTemplate.allCases.enumerated()), id: \.element.id) { index, template in
                TemplateCard(
                    template: template,
                    pressed: pressed == template,
                    onTap: {
                        pressed = template
                        CucuHaptics.soft()
                        // Slight delay so the press scale lands before
                        // the parent swaps the document — feels like
                        // the card "lifts up" before the page repaints.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onPick(template)
                        }
                    }
                )
                .opacity(cardsVisible ? 1 : 0)
                .offset(y: cardsVisible ? 0 : 12)
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.82)
                        .delay(0.28 + Double(index) * 0.04),
                    value: cardsVisible
                )
            }
        }
    }

    private var skipButton: some View {
        Button(action: onSkip) {
            Text("Start from a blank page")
                .font(.cucuSans(13, weight: .medium))
                .foregroundStyle(Color.cucuInkFaded)
                .underline()
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .opacity(skipVisible ? 1 : 0)
    }
}

private struct TemplateCard: View {
    let template: ProfileTemplate
    let pressed: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                meta
            }
            .frame(maxWidth: .infinity)
            .background(Color.cucuCardSoft)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: pressed)
        }
        .buttonStyle(CucuPressableButtonStyle())
        .accessibilityLabel(Text("\(template.title). \(template.tagline)"))
    }

    /// Mini-preview of the template's page chrome — the same hex
    /// `theme.apply` will paint on the page, plus a centered SF
    /// Symbol so the card has a focal point without us needing
    /// per-template artwork.
    private var preview: some View {
        ZStack {
            Color(hex: template.previewBackgroundHex)
                .frame(height: 120)
            VStack(spacing: 6) {
                Image(systemName: template.iconSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(hex: template.previewAccentHex))
                Capsule()
                    .fill(Color(hex: template.previewAccentHex).opacity(0.6))
                    .frame(width: 40, height: 4)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 18,
                style: .continuous
            )
        )
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.title)
                .font(.cucuSerif(15, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .lineLimit(1)
            Text(template.tagline)
                .font(.cucuSans(11, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

