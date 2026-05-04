import SwiftUI

/// Modal that lets a viewer report a post for one of the SQL-
/// constrained reasons. Phase 7's first user-facing moderation
/// affordance — App Store Guideline 1.2 requires this surface for
/// any UGC app.
///
/// Auth-gated mirroring the `PublishSheet` pattern: the sheet
/// renders `AuthGateView` when the viewer is signed out, then
/// swaps to the form once auth lands. Reporting requires being
/// signed in — `post_reports_insert_own` enforces that server-
/// side too.
///
/// Three terminal states:
///   - **submitted**       — sheet dismisses, parent shows toast
///   - **alreadyReported** — friendly inline note (not a retry
///                           prompt); the parent treats this the
///                           same as success and dismisses with
///                           a "we already have it" toast.
///   - **error**           — inline message + retry; the sheet
///                           stays mounted so the user keeps
///                           their picked reason / typed note.
struct ReportPostSheet: View {
    /// What happened, surfaced back to the parent on dismiss.
    /// `Binding` would conflate "I'm done" with "what happened";
    /// a closure-with-result is cleaner because the parent picks
    /// the toast copy.
    enum Outcome: Equatable {
        case submitted
        case alreadyReported
        case cancelled
    }

    let post: Post
    var onFinish: (Outcome) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth
    @State private var reason: ReportReason = .spam
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var inlineError: String?
    /// Set when the server returns `alreadyReported`. Drives the
    /// friendly inline copy + a different dismiss path (so the
    /// parent's toast reads "already reported" instead of
    /// "thanks for reporting").
    @State private var alreadyReportedNotice: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    AuthGateView()
                } else {
                    form
                }
            }
            .cucuSheetTitle("Report post")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onFinish(.cancelled)
                        dismiss()
                    }
                    .foregroundStyle(Color.cucuInk)
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Reason", selection: $reason) {
                    ForEach(ReportReason.allCases) { reason in
                        Text(reason.displayLabel).tag(reason)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                CucuSectionLabel(text: "Why are you reporting this?")
            }

            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $note)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.cucuBone)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.cucuInk, lineWidth: 1)
                        )
                    if note.isEmpty {
                        Text("Add a note (optional)")
                            .font(.cucuEditorial(15, italic: true))
                            .foregroundStyle(Color.cucuInkFaded)
                            .padding(.top, 18)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }
                }
                HStack {
                    Spacer()
                    Text("\(note.count) / \(PostReportService.noteCharacterLimit)")
                        .font(.cucuMono(11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(noteCounterTone)
                }
            } header: {
                CucuSectionLabel(text: "Notes for moderators")
            } footer: {
                Text("If you can, tell us what's wrong with this post. We review every report.")
                    .font(.cucuEditorial(12, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
            }

            if alreadyReportedNotice {
                Section {
                    Label {
                        Text("You already reported this post. Our team will review it soon.")
                            .font(.cucuEditorial(13, italic: true))
                            .foregroundStyle(Color.cucuInkSoft)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Color.cucuMoss)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cucuMossSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.cucuMoss.opacity(0.4), lineWidth: 1)
                    )
                    .listRowBackground(Color.clear)
                }
            } else if let inlineError {
                Section {
                    Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                        .font(.cucuEditorial(13, italic: true))
                        .foregroundStyle(Color.cucuBurgundy)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .tint(Color.cucuInk)
                        } else {
                            submitChip
                        }
                        Spacer()
                    }
                }
                .buttonStyle(CucuPressableButtonStyle())
                .disabled(isSubmitting || note.count > PostReportService.noteCharacterLimit)
                .listRowBackground(Color.clear)
            }
        }
        .cucuFormBackdrop()
        .scrollDismissesKeyboard(.interactively)
    }

    /// Submit chip — burgundy variant when the user is filing a
    /// fresh report (the destructive read), moss variant for the
    /// "Done" branch after the server returned `alreadyReported`
    /// (the affirmative read).
    @ViewBuilder
    private var submitChip: some View {
        let isDone = alreadyReportedNotice
        HStack(spacing: 6) {
            Image(systemName: isDone ? "checkmark" : "flag.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(isDone ? "Done" : "Submit report")
                .font(.cucuSerif(14, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .foregroundStyle(isDone ? Color.cucuMoss : Color.cucuBurgundy)
        .background(Capsule().fill(isDone ? Color.cucuMossSoft : Color.cucuRose))
        .overlay(
            Capsule().strokeBorder(
                isDone ? Color.cucuMoss : Color.cucuRoseStroke,
                lineWidth: 1
            )
        )
    }

    /// Three-tier counter colour — paper ink while comfortable,
    /// burgundy on the warning band, cherry once the writer's
    /// blown past the server-enforced cap.
    private var noteCounterTone: Color {
        if note.count > PostReportService.noteCharacterLimit { return .cucuCherry }
        if note.count > Int(Double(PostReportService.noteCharacterLimit) * 0.85) { return .cucuBurgundy }
        return .cucuInkSoft
    }

    private func submit() async {
        // The "Done" button on the alreadyReported branch also
        // routes through `submit()` — short-circuit and treat it
        // as "we already told you, just dismiss now".
        if alreadyReportedNotice {
            onFinish(.alreadyReported)
            dismiss()
            return
        }
        inlineError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await PostReportService().report(
                postId: post.id,
                reason: reason,
                note: note.isEmpty ? nil : note
            )
            CucuHaptics.success()
            onFinish(.submitted)
            dismiss()
        } catch let err as PostReportError {
            switch err {
            case .alreadyReported:
                alreadyReportedNotice = true
            default:
                inlineError = err.errorDescription ?? "Couldn't submit your report."
            }
        } catch {
            inlineError = error.localizedDescription
        }
    }
}
