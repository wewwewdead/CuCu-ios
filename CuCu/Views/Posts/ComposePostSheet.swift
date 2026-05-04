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
    @Environment(CucuPostFlightCoordinator.self) private var flightCoordinator

    let parentId: String?
    var parentPreview: ParentPreview? = nil
    /// Fired with the inserted `Post` after a successful submit so
    /// the caller can prepend it to a feed without a refetch.
    var onPosted: (Post) -> Void = { _ in }

    /// When `true`, a successful submit launches the post-flight
    /// animation (ghost card flying from this sheet up to the feed)
    /// and skips the immediate `onPosted` callback. The feed picks
    /// up the new post via the coordinator's `landedPostId` so the
    /// row materialises exactly when the ghost dissolves into it,
    /// not earlier. Replies and other non-feed callers leave this
    /// off and keep the original "prepend on success" path.
    var usesFlight: Bool = false

    @State private var vm = ComposePostViewModel()
    @State private var showDiscardConfirm = false
    @FocusState private var bodyFocused: Bool

    /// Submit button center-x in window coordinates, captured by a
    /// background `GeometryReader` so the flight ghost emerges
    /// directly above where the user just tapped. We snapshot this
    /// at submit time so the value is stable even if the sheet's
    /// dismissal is reflowing the layout.
    @State private var submitCenterX: CGFloat = 0

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
            .cucuSheetTitle(navigationTitle)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestDismiss() }
                        .foregroundStyle(Color.cucuInk)
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
                if usesFlight {
                    // Hand the post off to the flight coordinator —
                    // it owns the choreography from here, including
                    // the success haptic on landing. We deliberately
                    // skip `onPosted` so the feed doesn't prepend
                    // the row twice (once now, once on land); the
                    // feed instead observes `landedPostId` and
                    // pulls the post off the coordinator at land.
                    flightCoordinator.launch(post: post, sourceX: submitCenterX)
                } else {
                    CucuHaptics.success()
                    onPosted(post)
                }
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
            VStack(alignment: .leading, spacing: 14) {
                masthead

                if let preview = parentPreview {
                    parentPreviewRow(preview)
                }

                editor

                if case .failure(let message) = vm.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.cucuEditorial(13, italic: true))
                        .foregroundStyle(Color.cucuBurgundy)
                        .padding(.horizontal, 4)
                }

                Rectangle()
                    .fill(Color.cucuInkRule)
                    .frame(height: 1)
                    .padding(.top, 2)

                HStack {
                    counter
                    Spacer()
                    submitButton
                }
            }
            .padding(16)
        }
        .background(Color.cucuPaper.ignoresSafeArea())
        .onAppear {
            CucuHaptics.soft()
            bodyFocused = true
        }
    }

    // MARK: - Masthead
    //
    // Borrows the feed's masthead idiom so the compose sheet
    // reads as a printed page being filled in: serif display
    // title, tracked-mono spec line (`TO @USERNAME` for replies,
    // current month/year for new posts), Fraunces-italic
    // subtitle, closed off by a 1pt ink hairline. Sized one
    // notch smaller than the feed's masthead since the sheet's
    // nav bar already carries the inline title.

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mastheadTitle)
                .font(.cucuSerif(30, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .accessibilityAddTraits(.isHeader)
            Text(mastheadSpecLine)
                .font(.cucuMono(10, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.top, 2)
            Text(mastheadSubtitle)
                .font(.cucuEditorial(14, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .padding(.bottom, 12)
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mastheadTitle: String {
        parentId == nil ? "New post" : "Reply"
    }

    private var mastheadSpecLine: String {
        if let preview = parentPreview {
            return "TO @\(preview.authorUsername)".uppercased()
        }
        let f = DateFormatter()
        f.dateFormat = "MMMM · yyyy"
        return f.string(from: Date()).uppercased()
    }

    private var mastheadSubtitle: String {
        parentId == nil
            ? "Leave a mark on the page."
            : "Add a thoughtful answer."
    }

    /// Parent preview as a printed pull-quote — a 2pt ink rule
    /// runs the full leading edge of the card (read as a
    /// quotation bracket), with a tracked "REPLYING TO" micro
    /// label, the parent author's handle in serif, and the body
    /// excerpt wrapped in curly quotes set in italic Fraunces.
    /// Soft card fill keeps it secondary to the editor below.
    private func parentPreviewRow(_ preview: ParentPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REPLYING TO")
                .font(.cucuMono(9, weight: .medium))
                .tracking(2.0)
                .foregroundStyle(Color.cucuInkFaded)
            Text("@\(preview.authorUsername)")
                .font(.cucuSerif(14, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
            Text("\u{201C}\(preview.bodyPreview)\u{201D}")
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cucuCardSoft)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.cucuInk)
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var editor: some View {
        // `TextEditor` keeps autocorrect / autocapitalize on by
        // default, which is what we want for social-style text —
        // the opposite of the username field that disables both.
        TextEditor(text: $vm.body)
            .focused($bodyFocused)
            .scrollContentBackground(.hidden)
            .background(Color.cucuBone)
            .frame(minHeight: 200)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cucuBone)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cucuInk, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                // Native placeholder — TextEditor doesn't supply
                // one, so we layer a Text on top while empty.
                if vm.body.isEmpty {
                    Text(parentId == nil
                         ? "What's happening?"
                         : "Write your reply…")
                        .font(.cucuEditorial(17, italic: true))
                        .foregroundStyle(Color.cucuInkFaded)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Counter pill — paper capsule that tilts toward warning
    /// tones as the user nears the limit. Three tiers:
    ///   - `> 50` remaining → ink-on-card, the resting state
    ///   - `≤ 50` remaining → burgundy-on-rose, "running short"
    ///   - `≤ 0`  remaining → cherry-on-rose, "you're over"
    private var counter: some View {
        let remaining = vm.remainingChars
        let palette = counterPalette(remaining: remaining)
        return Text("\(remaining)")
            .font(.cucuMono(12, weight: .medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(palette.fill))
            .overlay(Capsule().strokeBorder(palette.stroke, lineWidth: 1))
            .accessibilityLabel("\(remaining) characters remaining")
    }

    private func counterPalette(remaining: Int) -> (text: Color, fill: Color, stroke: Color) {
        if remaining <= 0 {
            return (.cucuCherry, .cucuRose, .cucuRoseStroke)
        }
        if remaining <= 50 {
            return (.cucuBurgundy, .cucuRose, .cucuRoseStroke)
        }
        return (.cucuInk, .cucuCard, .cucuInk)
    }

    /// Monochrome submit, paired visually with the Sign In and
    /// Sign Up chips: solid ink fill on paper text, asymmetric
    /// pebble shape that leans trailing-side toward the action,
    /// and a paper hairline inset 3pt for letterpress detail.
    /// The faded `✦` flourish — the same closer used by the feed
    /// and thread columns — survives in paper-tinted form. The
    /// in-flight state swaps in italic Fraunces "Sending…"
    /// alongside the spinner so the transition stays in voice.
    private var submitButton: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 18,
            bottomTrailingRadius: 28, topTrailingRadius: 28,
            style: .continuous
        )
        return Button {
            Task {
                guard let user = auth.currentUser else { return }
                await vm.submit(user: user, parentId: parentId)
            }
        } label: {
            HStack(spacing: 9) {
                if vm.isSubmitting {
                    ProgressView()
                        .tint(Color.cucuPaper)
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.cucuEditorial(14, italic: true))
                } else {
                    Text(parentId == nil ? "Post" : "Reply")
                        .font(.cucuSerif(16, weight: .bold))
                        .tracking(0.6)
                    Text("✦")
                        .font(.cucuSerif(13, weight: .regular))
                        .foregroundStyle(Color.cucuPaper.opacity(0.6))
                }
            }
            .foregroundStyle(Color.cucuPaper)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(minWidth: 124)
            .background(shape.fill(Color.cucuInk))
            .overlay(
                shape
                    .inset(by: 3)
                    .strokeBorder(Color.cucuPaper.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.cucuInk.opacity(0.18), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(!vm.canSubmit)
        .opacity(vm.canSubmit ? 1.0 : 0.35)
        .accessibilityLabel(parentId == nil ? "Post" : "Reply")
        // Snapshot the button's center-x in window coordinates so
        // the flight overlay can launch the ghost card from the
        // exact horizontal position the user just tapped. Cheap to
        // re-read here — `.global` resolves on the same pass as
        // the rest of layout. Only used when `usesFlight` is on.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        submitCenterX = geo.frame(in: .global).midX
                    }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        submitCenterX = newFrame.midX
                    }
            }
        )
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
