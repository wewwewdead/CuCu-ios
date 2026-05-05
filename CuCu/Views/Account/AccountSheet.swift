import SwiftUI

/// Account surface presented from the editor toolbar — the canonical
/// place to sign in, sign out, and manage privacy + moderation
/// settings. Outside the publish flow so users don't have to start
/// a publish to manage their session.
///
/// Body branches on auth state:
///   - signed out → AuthGateView (sign-in / sign-up tabs)
///   - signed in but unclaimed → UsernamePickerView (one-time, post-signup)
///   - signed in and claimed → refined account list
///
/// The signed-in surface uses the refined-minimalist primitives
/// (snow page, hairline-divided rows, bold Lexend labels). The
/// auth-gate and username-picker branches keep their existing
/// editorial chrome — those are content-creation flavoured surfaces
/// that the refined system doesn't replace.
struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openURL) private var openURL
    @State private var chrome = AppChromeStore.shared

    /// App Store submission requires a working support email.
    /// Reading from Info.plist lets the deployable email change
    /// without a code edit; the fallback keeps the surface
    /// functional during development.
    private var supportEmail: String {
        (Bundle.main.object(forInfoDictionaryKey: "CuCuSupportEmail") as? String)
            ?? "support@cucu.app"
    }

    private let termsURL = URL(string: "https://cucu.app/terms")!
    private let privacyURL = URL(string: "https://cucu.app/privacy")!

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    AuthGateView()
                        .cucuSheetTitle("Account")
                } else if auth.requiresUsernameClaim {
                    UsernamePickerView()
                        .cucuSheetTitle("Account")
                } else {
                    accountContent
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
            }
        }
    }

    // MARK: - Refined account list

    private var accountContent: some View {
        ZStack {
            CucuRefinedPageBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    identityHeader

                    privacySection
                    CucuRefinedDivider()

                    supportSection

                    if auth.currentUser?.isModerator == true {
                        CucuRefinedDivider()
                        moderationSection
                    }

                    if auth.currentUser?.isAdmin == true {
                        CucuRefinedDivider()
                        adminSection
                    }

                    CucuRefinedPillButton("Sign Out", role: .destructive) {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    }
                    .padding(.top, 8)
                    .disabled(auth.isLoading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .cucuRefinedNav("Account")
    }

    /// Top "you" block — handle on top in bold Lexend, email
    /// underneath in faded ink. Wrapped in a row-shaped container so
    /// the page reads as a stack of refined entries from the top
    /// down.
    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            CucuRefinedSectionLabel(text: "Signed in as")
            HStack(spacing: 14) {
                Circle()
                    .fill(chrome.theme.cardColor)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(chrome.theme.inkPrimary)
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().strokeBorder(chrome.theme.rule, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(auth.currentUser?.username ?? "")")
                        .font(.cucuSans(17, weight: .bold))
                        .foregroundStyle(chrome.theme.inkPrimary)
                        .lineLimit(1)
                    Text(auth.currentUser?.email ?? "")
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CucuRefinedSectionLabel(text: "Privacy")
                .padding(.bottom, 4)
            NavigationLink {
                BlockedUsersListView()
            } label: {
                CucuRefinedListRow(
                    title: "Blocked users",
                    subtitle: nil,
                    leading: { CucuRefinedAvatarTile(source: .glyph("hand.raised")) },
                    trailing: { chevron }
                )
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
            CucuRefinedDivider()
            CucuRefinedListRow(
                title: "Terms of Service",
                subtitle: nil,
                leading: { CucuRefinedAvatarTile(source: .glyph("doc.text")) },
                trailing: { chevron },
                onTap: { openURL(termsURL) }
            )
            CucuRefinedDivider()
            CucuRefinedListRow(
                title: "Privacy Policy",
                subtitle: nil,
                leading: { CucuRefinedAvatarTile(source: .glyph("lock.shield")) },
                trailing: { chevron },
                onTap: { openURL(privacyURL) }
            )
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CucuRefinedSectionLabel(text: "Support")
                .padding(.bottom, 4)
            CucuRefinedListRow(
                title: supportEmail,
                subtitle: nil,
                leading: { CucuRefinedAvatarTile(source: .glyph("envelope")) },
                trailing: { chevron },
                onTap: {
                    if let url = URL(string: "mailto:\(supportEmail)") {
                        openURL(url)
                    }
                }
            )
        }
    }

    private var moderationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CucuRefinedSectionLabel(text: "Moderation")
                .padding(.bottom, 4)
            NavigationLink {
                ModerationQueueView()
            } label: {
                CucuRefinedListRow(
                    title: "Moderation queue",
                    subtitle: nil,
                    leading: { CucuRefinedAvatarTile(source: .glyph("flag")) },
                    trailing: { chevron }
                )
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
        }
    }

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CucuRefinedSectionLabel(text: "Admin")
                .padding(.bottom, 4)
            NavigationLink {
                RoleManagementView()
            } label: {
                CucuRefinedListRow(
                    title: "Manage roles",
                    subtitle: nil,
                    leading: { CucuRefinedAvatarTile(source: .glyph("person.crop.rectangle.badge.plus")) },
                    trailing: { chevron }
                )
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
        }
    }

    /// Trailing chevron for tap-rows. Sized + tinted to match the
    /// faded ink so the row reads as flat with a quiet "more here"
    /// hint instead of a system blue arrow.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(chrome.theme.inkFaded)
    }
}
