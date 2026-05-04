import SwiftUI

/// One-time acceptance modal for the no-tolerance content policy
/// (Apple Guideline 1.2). Shown after a brand-new account claims a
/// username; existing pre-Phase-7 users are grandfathered by the
/// `runEULAMigrationIfNeeded` migration in `AuthViewModel`.
///
/// Persists acceptance through `AuthViewModel.acceptEULA()`, which
/// writes through to `@AppStorage("cucu.eula_accepted_v1")`.
/// Versioned key so a v2 policy can re-prompt without touching v1
/// state.
struct EULAAcceptanceView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openURL) private var openURL

    // TODO(Phase 8): real Terms URL once legal lands the copy.
    private let termsURL = URL(string: "https://cucu.app/terms")!

    /// "What's not allowed" bullets — kept short and concrete so a
    /// reviewer can verify Guideline 1.2's coverage at a glance.
    private let prohibitedItems: [(icon: String, text: String)] = [
        ("hand.raised", "No harassment, hate speech, or bullying."),
        ("exclamationmark.shield", "No sexual content involving minors."),
        ("exclamationmark.triangle", "No violence, threats, or graphic content."),
        ("envelope.badge", "No spam, scams, or off-platform solicitation."),
        ("person.crop.circle.badge.questionmark", "No impersonation of others.")
    ]

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    bulletList
                    termsLink
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
        .safeAreaInset(edge: .bottom) {
            agreeBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("❦")
                .font(.cucuSerif(40, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text("Welcome to CuCu")
                .font(.cucuSerif(28, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text("Before you post or comment, please agree to our content rules. We don't tolerate objectionable content — and we act fast when something gets reported.")
                .font(.cucuEditorial(14, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 12) {
            CucuSectionLabel(text: "What's not allowed")
            ForEach(prohibitedItems, id: \.text) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(Color.cucuBurgundy)
                        .frame(width: 22)
                    Text(item.text)
                        .font(.cucuSans(14))
                        .foregroundStyle(Color.cucuInk)
                }
            }
        }
    }

    private var termsLink: some View {
        Button {
            openURL(termsURL)
        } label: {
            Label("Read full Terms of Service", systemImage: "doc.text")
                .font(.cucuSerif(13, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(Color.cucuInk)
    }

    /// Bottom safe-area inset — paper-toned with a top hairline so
    /// the action bar reads as a printed footer, not a floating
    /// material strip. The agree button is the only affordance.
    private var agreeBar: some View {
        ZStack(alignment: .top) {
            Color.cucuPaper.ignoresSafeArea(edges: .bottom)
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
            agreeChip
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    private var agreeChip: some View {
        Button {
            CucuHaptics.success()
            auth.acceptEULA()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("I agree")
                    .font(.cucuSerif(17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(Color.cucuMoss)
            .background(Capsule().fill(Color.cucuMossSoft))
            .overlay(Capsule().strokeBorder(Color.cucuMoss, lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
        .controlSize(.large)
    }
}
