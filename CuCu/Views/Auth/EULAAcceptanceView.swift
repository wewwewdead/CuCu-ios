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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                bulletList
                termsLink
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .safeAreaInset(edge: .bottom) {
            agreeButton
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to CuCu")
                .font(.title.weight(.semibold))
            Text("Before you post or comment, please agree to our content rules. We don't tolerate objectionable content — and we act fast when something gets reported.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's not allowed")
                .font(.headline)
            ForEach(prohibitedItems, id: \.text) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(item.text)
                        .font(.callout)
                }
            }
        }
    }

    private var termsLink: some View {
        Button {
            openURL(termsURL)
        } label: {
            Label("Read full Terms of Service", systemImage: "doc.text")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private var agreeButton: some View {
        Button {
            auth.acceptEULA()
        } label: {
            HStack {
                Spacer()
                Text("I agree").fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
