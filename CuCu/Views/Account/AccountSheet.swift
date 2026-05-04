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
            .cucuSheetTitle("Account")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.cucuInk)
                }
            }
        }
    }

    private var accountContent: some View {
        Form {
            Section {
                Text(auth.currentUser?.email ?? "")
                    .font(.cucuMono(13, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
                Text("@\(auth.currentUser?.username ?? "")")
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
            } header: {
                CucuSectionLabel(text: "Account")
            }

            Section {
                NavigationLink {
                    BlockedUsersListView()
                } label: {
                    accountRow(label: "Blocked users", systemImage: "hand.raised")
                }
                Button {
                    openURL(termsURL)
                } label: {
                    accountRow(label: "Terms of Service", systemImage: "doc.text")
                }
                Button {
                    openURL(privacyURL)
                } label: {
                    accountRow(label: "Privacy Policy", systemImage: "lock.shield")
                }
            } header: {
                CucuSectionLabel(text: "Privacy")
            }

            Section {
                Button {
                    if let url = URL(string: "mailto:\(supportEmail)") {
                        openURL(url)
                    }
                } label: {
                    accountRow(label: supportEmail, systemImage: "envelope")
                }
            } header: {
                CucuSectionLabel(text: "Support")
            }

            // Mod-only: hidden when `isModerator` is false. Server-
            // side RLS would also empty the queue for a non-mod,
            // but the UI gate prevents the wasted request.
            if auth.currentUser?.isModerator == true {
                Section {
                    NavigationLink {
                        ModerationQueueView()
                    } label: {
                        accountRow(label: "Moderation queue", systemImage: "flag")
                    }
                } header: {
                    CucuSectionLabel(text: "Moderation")
                }
            }

            // Admin-only: same UI-gate pattern. Granting a role
            // would 42501 / RLS-deny on the server too.
            if auth.currentUser?.isAdmin == true {
                Section {
                    NavigationLink {
                        RoleManagementView()
                    } label: {
                        accountRow(label: "Manage roles", systemImage: "person.crop.rectangle.badge.plus")
                    }
                } header: {
                    CucuSectionLabel(text: "Admin")
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
                        Text("Sign Out")
                            .font(.cucuSerif(15, weight: .semibold))
                            .foregroundStyle(Color.cucuBurgundy)
                        Spacer()
                    }
                }
                .disabled(auth.isLoading)
            }
        }
        .cucuFormBackdrop()
    }

    /// Shared visual treatment for every link / button row in the
    /// account form. Pulls the icon into ink-soft and keeps body
    /// copy in deep ink so the rows scan as a list of editorial
    /// entries rather than system-blue chevrons.
    private func accountRow(label: String, systemImage: String) -> some View {
        Label {
            Text(label)
                .font(.cucuSans(15))
                .foregroundStyle(Color.cucuInk)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.cucuInkSoft)
        }
    }
}
