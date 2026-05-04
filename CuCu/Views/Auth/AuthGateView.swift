import SwiftUI

/// Sign-in / sign-up tab pair, used inside the publish sheet when the user
/// isn't signed in yet. Drafts and editing don't depend on this view —
/// it's only reachable through Publish.
///
/// After a successful sign-up, if the new account hasn't claimed a
/// username yet (`auth.requiresUsernameClaim`), this view swaps to
/// `UsernamePickerView` in place rather than letting the publish sheet
/// dismiss back to the publish form. Existing accounts whose username
/// was backfilled by the Phase 1 SQL migration skip the picker entirely.
struct AuthGateView: View {
    enum Mode: String, Hashable, CaseIterable {
        case signIn = "Sign In"
        case signUp = "Sign Up"
    }

    @Environment(AuthViewModel.self) private var auth
    @State private var mode: Mode = .signIn

    var body: some View {
        if auth.isSignedIn && auth.requiresUsernameClaim {
            UsernamePickerView()
        } else if auth.isSignedIn && auth.requiresEULAAcceptance {
            // Phase 7 — Apple Guideline 1.2 acceptance gate. The
            // username picker chains into this so brand-new
            // accounts do `claim → agree → land` in one
            // continuous flow. Pre-Phase-7 users are grandfathered
            // out of this branch by `runEULAMigrationIfNeeded`.
            EULAAcceptanceView()
        } else {
            authTabs
        }
    }

    private var authTabs: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                header

                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color.cucuInk)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .onChange(of: mode) { _, _ in
                    CucuHaptics.selection()
                    auth.clearMessages()
                }

                switch mode {
                case .signIn: SignInView()
                case .signUp: SignUpView()
                }
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
        VStack(spacing: 8) {
            Text("❦")
                .font(.cucuSerif(36, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text("Sign in to publish")
                .font(.cucuSerif(22, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text("You don't need an account to create or edit drafts. Sign in only to publish your profile online.")
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
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
        Label {
            Text(message)
                .font(.cucuEditorial(12, italic: true))
                .foregroundStyle(Color.cucuBurgundy)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.cucuBurgundy)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cucuRose.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cucuRoseStroke, lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}
