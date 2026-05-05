import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// One sheet that handles the full publish journey:
///
///   - if not signed in   → AuthGateView
///   - if signed in but unclaimed → UsernamePickerView (one-time, post-signup)
///   - if signed in, idle → publish form (no username field)
///   - while publishing   → progress
///   - on success         → public path + Done / Copy Path
///   - on failure         → message + Retry
///
/// The username lives on `auth.currentUser.username` from sign-in onward
/// (hydrated from the `usernames` table by `AuthViewModel`); the publish
/// service reads it off the `AppUser`. This sheet no longer asks for it.
///
/// Local draft state is updated only after a successful publish; the local
/// design itself is never mutated, so the offline builder keeps using local
/// asset paths.
struct PublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth
    @State private var chrome = AppChromeStore.shared

    @Bindable var draft: ProfileDraft
    /// V2 source-of-truth document. The publish service walks this for
    /// asset paths and serializes the path-rewritten copy as the cloud
    /// `design_json`. The local document is never mutated.
    let document: ProfileDocument
    /// Optional callback the host can use to reveal the published
    /// profile right after a successful publish (e.g., push the
    /// `PublishedProfileView` onto the same nav stack).
    var onViewPublished: ((String) -> Void)? = nil

    @State private var publishVM = PublishViewModel()
    @State private var showShareSheet = false
    @State private var copiedLinkMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                Group {
                    if !auth.isSignedIn || auth.requiresUsernameClaim {
                        // Pre-publish: not signed in *or* signed in but no
                        // username yet. AuthGateView routes between the
                        // sign-in/up tabs and the picker on its own.
                        AuthGateView()
                    } else {
                        publishContent
                    }
                }
            }
            .cucuRefinedNav(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSans(15, weight: .regular))
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
                // Sign Out / account-glance lives in the editor's
                // AccountSheet now; no per-sheet duplicate here.
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if case .success(let result) = publishVM.status {
                ProfileShareSheet(username: result.username, document: document)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert(
            "Link copied",
            isPresented: Binding(
                get: { copiedLinkMessage != nil },
                set: { if !$0 { copiedLinkMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { copiedLinkMessage = nil }
        } message: {
            Text(copiedLinkMessage ?? "")
        }
    }

    // MARK: - Content states

    /// Title flips to "Pick username" while the picker is on screen so
    /// the nav bar matches the form below it.
    private var navigationTitle: String {
        if auth.isSignedIn && auth.requiresUsernameClaim {
            return "Pick username"
        }
        return "Publish"
    }

    @ViewBuilder
    private var publishContent: some View {
        // Safety net: if we somehow landed inside `publishContent` with
        // no claimed username (state corruption, race after sign-out),
        // surface the picker instead of a form that can't submit.
        // Normal flow keeps this branch unreachable thanks to the
        // body-level gate on `requiresUsernameClaim`.
        if (auth.currentUser?.username ?? "").isEmpty {
            UsernamePickerView()
        } else {
            switch publishVM.status {
            case .idle:
                publishForm
            case .validating, .uploadingAssets, .savingProfile:
                publishProgress
            case .success(let result):
                publishSuccess(result)
            case .failure(let message):
                publishFailure(message)
            }
        }
    }

    private var publishForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                identityCard
                publishButton
                publishFooter
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    /// "Publishing as" card — username surfaced as a refined card row
    /// so it reads as deliberate metadata rather than a system Form
    /// section. Theme-aware throughout.
    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Publishing as")
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
            HStack(spacing: 4) {
                Text("@\(auth.currentUser?.username ?? "")")
                    .font(.cucuSans(17, weight: .bold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(chrome.theme.cardColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chrome.theme.rule, lineWidth: 1)
            )
        }
    }

    /// Primary publish action — refined ink-on-page pill. Disabled
    /// while a publish is in flight; the pill's opacity drops via
    /// the system's `.disabled` modifier so the user reads "not
    /// available right now" without a colour swap.
    private var publishButton: some View {
        Button {
            Task {
                guard let user = auth.currentUser else { return }
                await publishVM.publish(
                    user: user,
                    draft: draft,
                    document: document
                )
                if case .success(let result) = publishVM.status {
                    applySuccessToDraft(result)
                    CucuProfileEvents.broadcastAvatarChange(username: result.username)
                }
            }
        } label: {
            Text("Publish")
                .font(.cucuSans(16, weight: .bold))
                .foregroundStyle(chrome.theme.pageColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(chrome.theme.inkPrimary)
                )
        }
        .buttonStyle(.plain)
        .disabled(publishVM.isWorking)
        .opacity(publishVM.isWorking ? 0.4 : 1)
    }

    /// "Set for life" footer — small faded sentence below the
    /// action so the user knows what they're committing to.
    private var publishFooter: some View {
        Text("Your username is set for life. The published page lives at \(ProfileShareLink.linkString(username: auth.currentUser?.username ?? "")).")
            .font(.cucuSans(12, weight: .regular))
            .foregroundStyle(chrome.theme.inkFaded)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var publishProgress: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(chrome.theme.inkPrimary)
            Text(progressLabel)
                .font(.cucuSans(15, weight: .medium))
                .foregroundStyle(chrome.theme.inkFaded)
            Spacer()
        }
        .padding()
    }

    private func publishSuccess(_ result: PublishedProfileResult) -> some View {
        VStack(spacing: 18) {
            // Fire the success haptic on the first frame the
            // success card is on screen.
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { CucuHaptics.success() }

            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(chrome.theme.isDark ? 0.22 : 0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 6) {
                Text("Published")
                    .font(.cucuSans(20, weight: .bold))
                    .foregroundStyle(chrome.theme.inkPrimary)
                Text(ProfileShareLink.linkString(username: result.username))
                    .font(.cucuSans(14, weight: .regular))
                    .foregroundStyle(chrome.theme.inkFaded)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 10) {
                CucuRefinedPillButton("View Profile") {
                    onViewPublished?(result.username)
                    dismiss()
                }
                CucuRefinedPillButton("Share Profile") {
                    showShareSheet = true
                }
                CucuRefinedPillButton("Copy path") {
                    copyToClipboard(ProfileShareLink.linkString(username: result.username))
                }
                CucuRefinedPillButton("Done") {
                    dismiss()
                }
            }
            .padding(.horizontal, 28)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func publishFailure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(chrome.theme.isDark ? 0.22 : 0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }
            Text("Publish failed")
                .font(.cucuSans(20, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(message)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(spacing: 10) {
                CucuRefinedPillButton("Try again") {
                    publishVM.reset()
                }
                CucuRefinedPillButton("Cancel") {
                    dismiss()
                }
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    // MARK: - Helpers

    private var progressLabel: String {
        switch publishVM.status {
        case .validating: return "Validating…"
        case .uploadingAssets: return "Uploading images…"
        case .savingProfile: return "Saving profile…"
        default: return ""
        }
    }

    private func applySuccessToDraft(_ result: PublishedProfileResult) {
        draft.publishedProfileId = result.profileId
        draft.publishedUsername = result.username
        draft.lastPublishedAt = .now
        // Stamp the canonical (lowercased) owner id so a later
        // sign-out + sign-up on this device drops the stale pointer
        // instead of trying to upsert into someone else's row.
        draft.publishedOwnerUserId = auth.currentUser?.id.lowercased()
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.string = text
        CucuHaptics.success()
        copiedLinkMessage = text
        #endif
    }
}
