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
///
/// Refined-minimalist surface: theme-aware page (snow / bone /
/// midnight all read through `chrome.theme.pageColor`), Lexend
/// bold display title, faded-ink subtitle, parent preview card on
/// a soft chrome recess, page-recess editor pill, refined pill
/// submit button. Drops the editorial chrome (Fraunces italic
/// placeholders, tracked mono spec lines, ✦ flourishes, asymmetric
/// pebble button) — the compose surface now matches the rest of
/// the social chrome.
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
    @State private var chrome = AppChromeStore.shared

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
                        .cucuSheetTitle(navigationTitle)
                } else if auth.requiresUsernameClaim {
                    UsernamePickerView()
                        .cucuSheetTitle(navigationTitle)
                } else {
                    composeContent
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestDismiss() }
                        .foregroundStyle(chrome.theme.inkPrimary)
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
        // re-renders. Top-level placement keeps the observer alive
        // for the entire lifetime of the sheet.
        .onChange(of: vm.status) { _, newStatus in
            if case .success(let post) = newStatus {
                if usesFlight {
                    // Hand the post off to the flight coordinator —
                    // it owns the choreography from here, including
                    // the success haptic on landing. Skip `onPosted`
                    // so the feed doesn't prepend the row twice (once
                    // now, once on land); the feed instead observes
                    // `landedPostId` and pulls the post off the
                    // coordinator at land.
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
                .cucuSheetTitle(navigationTitle)
        } else {
            // Render `composeForm` for every status, including
            // `.success`. The body-root `.onChange` consumes the
            // success transition and dismisses on the next tick —
            // we deliberately do NOT swap to a placeholder view
            // here, because doing so was tearing the observer
            // down before the change could be delivered.
            composeForm
                .cucuRefinedNav(navigationTitle)
        }
    }

    private var composeForm: some View {
        ZStack {
            CucuRefinedPageBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    masthead

                    if let preview = parentPreview {
                        parentPreviewRow(preview)
                    }

                    editor

                    if case .failure(let message) = vm.status {
                        Text(message)
                            .font(.cucuSans(13, weight: .regular))
                            .foregroundStyle(destructiveInk)
                            .padding(.horizontal, 4)
                    }

                    CucuRefinedDivider()
                        .padding(.top, 2)

                    HStack {
                        counter
                        Spacer()
                        submitButton
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            CucuHaptics.soft()
            bodyFocused = true
        }
    }

    // MARK: - Masthead
    //
    // Refined opening real estate. Drops the tracked-mono spec
    // line, the Fraunces-italic subtitle, and the hairline rule
    // (the divider above the counter row already closes the
    // section). Just a bold display heading + faded subtitle so
    // the user lands with context for what they're writing.

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mastheadTitle)
                .font(.cucuSans(28, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .accessibilityAddTraits(.isHeader)
            if let toLine = mastheadToLine {
                Text(toLine)
                    .font(.cucuSans(13, weight: .regular))
                    .foregroundStyle(chrome.theme.inkFaded)
                    .padding(.top, 2)
            }
            Text(mastheadSubtitle)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .padding(.top, 2)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mastheadTitle: String {
        parentId == nil ? "New post" : "Reply"
    }

    /// Sentence-case "to @username" line, only shown for replies.
    /// Drops the previous tracked-uppercase mono treatment in
    /// favour of a plain Lexend regular line that reads as
    /// metadata, not a printer's mark.
    private var mastheadToLine: String? {
        guard let preview = parentPreview else { return nil }
        return "to @\(preview.authorUsername)"
    }

    private var mastheadSubtitle: String {
        parentId == nil
            ? "Leave a mark on the page."
            : "Add a thoughtful answer."
    }

    // MARK: - Parent preview

    /// Refined parent preview. A soft chrome recess (matching the
    /// search field and reply bar) carries the "REPLYING TO" label
    /// in faded sans, the bold parent handle, and the body excerpt
    /// in regular Lexend. Drops the curly-quote italic Fraunces
    /// treatment and the heavy 2pt ink quotation rule — the chrome
    /// recess itself reads as quotation.
    private func parentPreviewRow(_ preview: ParentPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replying to")
                .font(.cucuSans(12, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
            Text("@\(preview.authorUsername)")
                .font(.cucuSans(15, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(preview.bodyPreview)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkMuted)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(chromeRecessFill)
        )
    }

    // MARK: - Editor

    /// Refined editor surface. Theme-aware fill (matches the
    /// search field and reply bar's chrome recess), no heavy ink
    /// stroke, no cream-paper hardcode. Placeholder is plain
    /// Lexend regular instead of Fraunces italic — reads as
    /// instruction, not editorial voice.
    private var editor: some View {
        TextEditor(text: $vm.body)
            .focused($bodyFocused)
            .scrollContentBackground(.hidden)
            .background(chromeRecessFill)
            .foregroundStyle(chrome.theme.inkPrimary)
            .font(.cucuSans(16, weight: .regular))
            .frame(minHeight: 200)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(chromeRecessFill)
            )
            .overlay(alignment: .topLeading) {
                // Native placeholder — TextEditor doesn't supply
                // one, so we layer a Text on top while empty.
                if vm.body.isEmpty {
                    Text(parentId == nil
                         ? "What's happening?"
                         : "Write your reply…")
                        .font(.cucuSans(16, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Counter

    /// Refined character counter — plain text in the chrome's
    /// faded ink at rest, shifting to a destructive tone as the
    /// user nears the limit. Drops the cream pill chrome; the
    /// number is information, not a chip.
    private var counter: some View {
        let remaining = vm.remainingChars
        return Text("\(remaining)")
            .font(.cucuSans(13, weight: .medium))
            .foregroundStyle(counterTint(remaining: remaining))
            .accessibilityLabel("\(remaining) characters remaining")
    }

    private func counterTint(remaining: Int) -> Color {
        if remaining <= 0 { return destructiveInk }
        if remaining <= 50 { return destructiveInk.opacity(0.75) }
        return chrome.theme.inkFaded
    }

    // MARK: - Submit button

    /// Refined submit. Solid ink-fill capsule with the page colour
    /// label so the button always has page-vs-ink contrast on any
    /// theme. Drops the asymmetric pebble + ✦ flourish in favour
    /// of a clean capsule — same shape language as the search
    /// field and reply bar.
    private var submitButton: some View {
        Button {
            Task {
                guard let user = auth.currentUser else { return }
                await vm.submit(user: user, parentId: parentId)
            }
        } label: {
            HStack(spacing: 6) {
                if vm.isSubmitting {
                    ProgressView()
                        .tint(chrome.theme.pageColor)
                        .controlSize(.small)
                    Text("Sending")
                        .font(.cucuSans(15, weight: .bold))
                } else {
                    Text(parentId == nil ? "Post" : "Reply")
                        .font(.cucuSans(15, weight: .bold))
                }
            }
            .foregroundStyle(chrome.theme.pageColor)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(minWidth: 110)
            .background(
                Capsule().fill(chrome.theme.inkPrimary)
            )
        }
        .buttonStyle(CucuRefinedSubmitButtonStyle())
        .disabled(!vm.canSubmit)
        .opacity(vm.canSubmit ? 1.0 : 0.35)
        .accessibilityLabel(parentId == nil ? "Post" : "Reply")
        // Snapshot the button's center-x in window coordinates so
        // the flight overlay can launch the ghost card from the
        // exact horizontal position the user just tapped.
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

    // MARK: - Tokens

    /// Subtle ink-against-page recess used by every input on the
    /// refined social chrome (search, reply bar, parent preview,
    /// editor). Theme-aware: a faint shadow on light themes, a
    /// faint highlight on dark themes.
    private var chromeRecessFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }

    /// Cherry tone for over-limit counter and inline submit
    /// errors. Same constant the refined pill button uses for the
    /// destructive role.
    private var destructiveInk: Color {
        Color(red: 178 / 255, green: 42 / 255, blue: 74 / 255)
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

/// Soft press response for the refined submit pill. Slight scale
/// + opacity dip so the button acknowledges the tap without the
/// shadow-heavy press state the editorial pebble had.
private struct CucuRefinedSubmitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
