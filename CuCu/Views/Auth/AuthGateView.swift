import SwiftUI

/// Sign-in / sign-up tab pair, used inside the publish sheet when the user
/// isn't signed in yet. Drafts and editing don't depend on this view —
/// it's only reachable through Publish.
struct AuthGateView: View {
    enum Mode: String, Hashable, CaseIterable {
        case signIn = "Sign In"
        case signUp = "Sign Up"
    }

    @Environment(AuthViewModel.self) private var auth
    @State private var mode: Mode = .signIn

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onChange(of: mode) { _, _ in auth.clearMessages() }

            switch mode {
            case .signIn: SignInView()
            case .signUp: SignUpView()
            }
        }
        .background {
            if let unavailability = auth.unavailability {
                unavailableHint(for: unavailability)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 60)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Sign in to publish")
                .font(.title3.weight(.semibold))
            Text("You don't need an account to create or edit drafts. Sign in only to publish your profile online.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func unavailableHint(for unavailability: SupabaseClientProvider.Unavailability) -> some View {
        let message: String = {
            switch unavailability {
            case .packageNotAdded:
                return "Add the Supabase Swift package via Xcode → File → Add Package Dependencies… to enable publishing."
            case .missingCredentials:
                return "Add your Supabase URL and anon key to CuCu/Config/SupabaseSecrets.plist to enable publishing."
            }
        }()
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
            .padding(.horizontal, 20)
    }
}
