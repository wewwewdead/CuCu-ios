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
            .navigationTitle("Report post")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onFinish(.cancelled)
                        dismiss()
                    }
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
                Text("Why are you reporting this?")
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Add a note (optional)")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $note)
                        .frame(minHeight: 96)
                }
                HStack {
                    Spacer()
                    Text("\(note.count) / \(PostReportService.noteCharacterLimit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(noteCounterTone)
                }
            } header: {
                Text("Notes for moderators")
            } footer: {
                Text("If you can, tell us what's wrong with this post. We review every report.")
            }

            if alreadyReportedNotice {
                Section {
                    Label(
                        "You already reported this post. Our team will review it soon.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            } else if let inlineError {
                Section {
                    Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
                        } else {
                            Text(alreadyReportedNotice ? "Done" : "Submit report")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isSubmitting || note.count > PostReportService.noteCharacterLimit)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var noteCounterTone: Color {
        if note.count > PostReportService.noteCharacterLimit { return .red }
        if note.count > Int(Double(PostReportService.noteCharacterLimit) * 0.85) { return .orange }
        return .secondary
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
