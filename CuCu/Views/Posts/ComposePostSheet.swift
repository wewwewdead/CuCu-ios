import SwiftUI

/// Sheet UI for creating a new post or reply.
///
/// Reuses the same auth gate `PublishSheet` does:
///
///   - signed out → `AuthGateView`
///   - signed in but no claimed username → `UsernamePickerView`
///   - signed in + claimed → compose form
///
/// Wrapped in a `NavigationStack` so the auth-gate's transition
/// from sign-in to picker animates through a real nav back-stack
/// (and the toolbar's Cancel sticks around in every sub-state).
struct ComposePostSheet: View {
    /// Lightweight preview shown above the editor when this sheet
    /// is presented as a reply. The replier sees the author handle
    /// and the first ~80 chars of the parent body so they're
    /// composing in context. Caller (`ReplyComposer`) is the only
    /// site that fills this in.
    struct ParentPreview: Equatable {
        let authorUsername: String
        let bodyPreview: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth

    let parentId: String?
    var parentPreview: ParentPreview? = nil
    /// Fired with the inserted `Post` after a successful submit so
    /// the caller can prepend it to a feed without a refetch.
    var onPosted: (Post) -> Void = { _ in }

    @State private var vm = ComposePostViewModel()
    @State private var showDiscardConfirm = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    AuthGateView()
                } else if auth.requiresUsernameClaim {
                    UsernamePickerView()
                } else {
                    composeContent
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestDismiss() }
                }
            }
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your post will be lost.")
        }
        // Anchor the success observer on the *root* of the sheet
        // body so it can't be torn down when an inner branch
        // re-renders. The previous attachment was on
        // `composeForm`, which got swapped out of the view tree
        // the instant status became `.success` — SwiftUI never
        // delivered the change, so `onPosted` and `dismiss`
        // never ran. Top-level placement keeps the observer
        // alive for the entire lifetime of the sheet.
        .onChange(of: vm.status) { _, newStatus in
            if case .success(let post) = newStatus {
                onPosted(post)
                dismiss()
            }
        }
    }

    // MARK: - Content states

    private var navigationTitle: String {
        if !auth.isSignedIn {
            return parentId == nil ? "New post" : "Reply"
        }
        if auth.requiresUsernameClaim {
            return "Pick username"
        }
        return parentId == nil ? "New post" : "Reply"
    }

    @ViewBuilder
    private var composeContent: some View {
        // Safety net mirroring `PublishSheet` — covers the rare
        // case where username drops back to nil mid-flow (e.g. the
        // user signed out via AccountSheet while this sheet was
        // mounted). Normal routing keeps this branch unreachable.
        if (auth.currentUser?.username ?? "").isEmpty {
            UsernamePickerView()
        } else {
            // Render `composeForm` for every status, including
            // `.success`. The body-root `.onChange` consumes the
            // success transition and dismisses on the next tick —
            // we deliberately do NOT swap to a placeholder view
            // here, because doing so was tearing the observer
            // down before the change could be delivered.
            composeForm
        }
    }

    private var composeForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let preview = parentPreview {
                    parentPreviewRow(preview)
                }

                editor

                if case .failure(let message) = vm.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }

                HStack {
                    counter
                    Spacer()
                    submitButton
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        #if os(iOS) || os(visionOS)
        .background(Color(.systemBackground).ignoresSafeArea())
        #endif
        .onAppear { bodyFocused = true }
    }

    private func parentPreviewRow(_ preview: ParentPreview) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(preview.authorUsername)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(preview.bodyPreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var editor: some View {
        // `TextEditor` keeps autocorrect / autocapitalize on by
        // default, which is what we want for social-style text —
        // the opposite of the username field that disables both.
        TextEditor(text: $vm.body)
            .focused($bodyFocused)
            .frame(minHeight: 160)
            .padding(8)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                // Native placeholder — TextEditor doesn't supply
                // one, so we layer a Text on top while empty.
                if vm.body.isEmpty {
                    Text(parentId == nil
                         ? "What's happening?"
                         : "Write your reply…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var counter: some View {
        Text("\(vm.remainingChars)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(counterColor)
            .accessibilityLabel("\(vm.remainingChars) characters remaining")
    }

    /// Three-tier counter colour matches the task spec exactly:
    /// secondary while comfortably under the limit, orange in the
    /// last 50 chars, red once the user has blown past zero.
    private var counterColor: Color {
        if vm.remainingChars <= 0 { return .red }
        if vm.remainingChars <= 50 { return .orange }
        return .secondary
    }

    private var submitButton: some View {
        Button {
            Task {
                guard let user = auth.currentUser else { return }
                await vm.submit(user: user, parentId: parentId)
            }
        } label: {
            if vm.isSubmitting {
                ProgressView()
                    .frame(minWidth: 60)
            } else {
                Text(parentId == nil ? "Post" : "Reply")
                    .fontWeight(.semibold)
                    .frame(minWidth: 60)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!vm.canSubmit)
    }

    // MARK: - Cancel handling

    /// Cancel: prompt for confirmation only when the user has
    /// typed something. Empty draft = no-op dismiss; non-empty =
    /// "are you sure?" so a stray tap doesn't lose their post.
    private func requestDismiss() {
        let trimmed = vm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dismiss()
        } else {
            showDiscardConfirm = true
        }
    }
}
