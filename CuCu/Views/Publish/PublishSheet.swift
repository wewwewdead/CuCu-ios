import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

/// One sheet that handles the full publish journey:
///
///   - if not signed in   → AuthGateView
///   - if signed in, idle → username form
///   - while publishing   → progress
///   - on success         → public path + Done / Copy Path
///   - on failure         → message + Retry
///
/// Local draft state is updated only after a successful publish; the local
/// design itself is never mutated, so the offline builder keeps using local
/// asset paths.
struct PublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth

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
    @State private var username: String = ""
    @State private var showShareSheet = false
    @State private var copiedLinkMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    AuthGateView()
                } else {
                    publishContent
                }
            }
            .navigationTitle("Publish")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if auth.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                Task { await auth.signOut() }
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            if let email = auth.currentUser?.email {
                                Text(email)
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
        }
        .onAppear {
            username = draft.publishedUsername ?? username
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

    @ViewBuilder
    private var publishContent: some View {
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

    private var publishForm: some View {
        Form {
            Section {
                HStack(spacing: 4) {
                    Text("@")
                        .foregroundStyle(.secondary)
                        .font(.body.monospaced())
                    TextField("yourname", text: $username)
                        .font(.body.monospaced())
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                if let hint = validationHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Username")
            } footer: {
                Text("Lowercase letters, numbers, and underscores. 3–30 characters.")
            }

            Section {
                Button {
                    Task {
                        guard let user = auth.currentUser else { return }
                        await publishVM.publish(
                            user: user,
                            draft: draft,
                            document: document,
                            username: username
                        )
                        if case .success(let result) = publishVM.status {
                            applySuccessToDraft(result)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Publish").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
            }
        }
    }

    private var publishProgress: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(progressLabel)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private func publishSuccess(_ result: PublishedProfileResult) -> some View {
        VStack(spacing: 18) {
            // Fire the success haptic on the first frame the
            // success card is on screen — once per `result.profileId`
            // so a re-publish to the same id doesn't double-pulse.
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { CucuHaptics.success() }

            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 6) {
                Text("Published!")
                    .font(.title3.weight(.semibold))
                Text(ProfileShareLink.linkString(username: result.username))
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button {
                    onViewPublished?(result.username)
                    dismiss()
                } label: {
                    Label("View Profile", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share Profile", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    copyToClipboard(ProfileShareLink.linkString(username: result.username))
                } label: {
                    Label("Copy path", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
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
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }
            Text("Publish failed")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(spacing: 10) {
                Button {
                    publishVM.reset()
                } label: {
                    Text("Try again")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    // MARK: - Helpers

    private var canSubmit: Bool {
        guard !username.isEmpty, validationHint == nil else { return false }
        return !publishVM.isWorking
    }

    private var validationHint: String? {
        guard !username.isEmpty else { return nil }
        switch UsernameValidator.validate(username) {
        case .success: return nil
        case .failure(let err): return err.errorDescription
        }
    }

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
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.string = text
        CucuHaptics.success()
        copiedLinkMessage = text
        #endif
    }
}
