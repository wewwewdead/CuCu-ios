import SwiftUI

/// Account surface presented from the editor toolbar — the canonical
/// place to sign in, sign out, and manage privacy + moderation
/// settings. Outside the publish flow so users don't have to start
/// a publish to manage their session.
///
/// Body branches on auth state:
///   - signed out → AuthGateView (sign-in / sign-up tabs)
///   - signed in but unclaimed → UsernamePickerView (one-time, post-signup)
///   - signed in and claimed → expanded account form
///
/// Navigation chrome mirrors `PublishSheet`: NavigationStack
/// wrapper, inline title, Cancel button on the left. The wrapper
/// also lets inner NavigationLinks (Blocked users, Moderation
/// queue, Manage roles) push without each screen having to provide
/// its own stack.
struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openURL) private var openURL

    /// App Store submission requires a working support email.
    /// Reading from Info.plist lets the deployable email change
    /// without a code edit; the fallback keeps the surface
    /// functional during development.
    // TODO: set CuCuSupportEmail in Info.plist before App Store submission
    private var supportEmail: String {
        (Bundle.main.object(forInfoDictionaryKey: "CuCuSupportEmail") as? String)
            ?? "support@cucu.app"
    }

    // TODO(Phase 8): replace placeholder Terms / Privacy URLs with
    // the live pages once legal lands the copy.
    private let termsURL = URL(string: "https://cucu.app/terms")!
    private let privacyURL = URL(string: "https://cucu.app/privacy")!

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    AuthGateView()
                } else if auth.requiresUsernameClaim {
                    UsernamePickerView()
                } else {
                    accountContent
                }
            }
            .navigationTitle("Account")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var accountContent: some View {
        Form {
            Section("Account") {
                Text(auth.currentUser?.email ?? "")
                Text("@\(auth.currentUser?.username ?? "")")
                    .font(.body.monospaced())
            }

            Section("Privacy") {
                NavigationLink {
                    BlockedUsersListView()
                } label: {
                    Label("Blocked users", systemImage: "hand.raised")
                }
                Button {
                    openURL(termsURL)
                } label: {
                    Label("Terms of Service", systemImage: "doc.text")
                        .foregroundStyle(Color.primary)
                }
                Button {
                    openURL(privacyURL)
                } label: {
                    Label("Privacy Policy", systemImage: "lock.shield")
                        .foregroundStyle(Color.primary)
                }
            }

            Section("Support") {
                Button {
                    if let url = URL(string: "mailto:\(supportEmail)") {
                        openURL(url)
                    }
                } label: {
                    Label(supportEmail, systemImage: "envelope")
                        .foregroundStyle(Color.primary)
                }
            }

            // Mod-only: hidden when `isModerator` is false. Server-
            // side RLS would also empty the queue for a non-mod,
            // but the UI gate prevents the wasted request.
            if auth.currentUser?.isModerator == true {
                Section("Moderation") {
                    NavigationLink {
                        ModerationQueueView()
                    } label: {
                        Label("Moderation queue", systemImage: "flag")
                    }
                }
            }

            // Admin-only: same UI-gate pattern. Granting a role
            // would 42501 / RLS-deny on the server too.
            if auth.currentUser?.isAdmin == true {
                Section("Admin") {
                    NavigationLink {
                        RoleManagementView()
                    } label: {
                        Label("Manage roles", systemImage: "person.crop.rectangle.badge.plus")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await auth.signOut()
                        dismiss()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(auth.isLoading)
            }
        }
    }
}
