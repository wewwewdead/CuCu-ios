import SwiftUI

/// Moderation queue — pushed from `AccountSheet` when the signed-in
/// user has `isModerator == true`. Lists every open report,
/// oldest-first, with three actions per row:
///   - "View thread" — push the conversation so a moderator can
///                     see context before acting
///   - "Take down"   — soft-delete the post via the mod RLS path
///                     and mark the report `actioned`
///   - "Dismiss"     — mark the report `dismissed` (post stays)
///
/// Both UI gating (this view) and SQL RLS
/// (`post_reports_select` checks `is_moderator(auth.uid())`) are
/// in place. UI gating saves a wasted query for a non-mod who
/// somehow lands on the screen; RLS is the real boundary.
struct ModerationQueueView: View {
    @State private var reports: [Report] = []
    @State private var status: Status = .loading
    /// Which slice of the queue is on screen. Open = actionable
    /// backlog (oldest first); History = audit trail of already-
    /// reviewed reports (newest first). Picker at the top of the
    /// view drives the segment.
    @State private var segment: Segment = .open
    /// Per-report row state for "Take down" / "Dismiss" so we can
    /// disable the buttons + paint a tiny spinner while the
    /// service call is in flight without blocking other rows.
    @State private var actionInFlight: Set<String> = []
    @State private var toastMessage: String? = nil

    private enum Status: Equatable {
        case loading
        case loaded
        case empty
        case error(String)
    }

    /// Open vs. History tab.
    private enum Segment: String, CaseIterable, Identifiable {
        case open = "Open"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            segmentPicker
            Group {
                switch status {
                case .loading:
                    loadingState
                case .empty:
                    emptyState
                case .loaded:
                    reportsList
                case .error(let message):
                    errorState(message)
                }
            }
        }
        .navigationTitle("Moderation")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: segment) { _, _ in
            // Reset reports + state machine when the user flips
            // between Open and History so a stale page from the
            // other segment doesn't flash before the new fetch
            // lands.
            reports = []
            status = .loading
            Task { await load() }
        }
        .cucuToast(message: $toastMessage)
    }

    private var segmentPicker: some View {
        Picker("", selection: $segment) {
            ForEach(Segment.allCases) { seg in
                Text(seg.rawValue).tag(seg)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - List

    private var reportsList: some View {
        List {
            ForEach(reports) { report in
                Section {
                    reportCard(report)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func reportCard(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: report)

            // Body of the reported post — bordered card so it
            // reads as a quote rather than chrome text.
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(report.postAuthorUsername)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(report.postBody.isEmpty ? "[post unavailable]" : report.postBody)
                    .font(.callout)
                    .lineLimit(4)
                    .truncationMode(.tail)
                Text(PostRowView.relativeTimestamp(for: report.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            if let note = report.note, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
            }

            // Segment branches the bottom row: open reports get
            // action buttons; history rows get the audit stamp.
            switch segment {
            case .open:
                actionRow(for: report)
            case .history:
                historyFooter(for: report)
            }
        }
        .padding(.vertical, 4)
    }

    /// Bottom-row treatment for the History segment — surfaces the
    /// resolved status (Taken down / Dismissed), the reviewer's
    /// `@handle`, and a relative timestamp. Plus a "View thread"
    /// link so a reviewing admin can still see the post (or its
    /// soft-deleted shell) for context.
    private func historyFooter(for report: Report) -> some View {
        HStack(spacing: 8) {
            statusBadge(for: report.status)
            if let reviewer = report.reviewerUsername {
                Text("by @\(reviewer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reviewedAt = report.reviewedAt {
                Text("· \(PostRowView.relativeTimestamp(for: reviewedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                PostThreadView(rootId: report.postRootId)
            } label: {
                Text("View thread")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusBadge(for status: ReportStatus) -> some View {
        let label: String
        let icon: String
        let tone: Color
        switch status {
        case .actioned:
            label = "Taken down"
            icon = "checkmark.shield"
            tone = .red
        case .dismissed:
            label = "Dismissed"
            icon = "hand.thumbsdown"
            tone = .secondary
        case .open:
            // Shouldn't appear in history, but render
            // defensively so a stale row from a race doesn't
            // crash.
            label = "Open"
            icon = "circle"
            tone = .orange
        }
        return Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(tone.opacity(0.12))
            )
    }

    private func header(for report: Report) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(report.reason.displayLabel, systemImage: reasonIcon(for: report.reason))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("via @\(report.reporterUsername)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(for report: Report) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                PostThreadView(rootId: report.postRootId)
            } label: {
                Label("View thread", systemImage: "bubble.left.and.bubble.right")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive) {
                Task { await takeDown(report) }
            } label: {
                if actionInFlight.contains(report.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Take down").font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(actionInFlight.contains(report.id))

            Button {
                Task { await dismiss(report) }
            } label: {
                Text("Dismiss").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(actionInFlight.contains(report.id))
        }
    }

    private func reasonIcon(for reason: ReportReason) -> String {
        switch reason {
        case .spam: return "envelope.badge"
        case .harassment: return "exclamationmark.bubble"
        case .sexual: return "eye.slash"
        case .violence: return "exclamationmark.triangle"
        case .selfHarm: return "heart.text.square"
        case .other: return "questionmark.circle"
        }
    }

    // MARK: - State surfaces

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch segment {
        case .open:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Inbox zero.")
                    .font(.headline)
                Text("No open reports right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .history:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nothing reviewed yet.")
                    .font(.headline)
                Text("Reports you action or dismiss will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load the queue")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Actions

    private func load() async {
        if reports.isEmpty { status = .loading }
        let activeSegment = segment
        do {
            let next: [Report]
            switch activeSegment {
            case .open:
                next = try await PostReportService().fetchOpenReports()
            case .history:
                next = try await PostReportService().fetchReviewedReports()
            }
            // Drop the result if the user flipped segments while
            // we were in flight — otherwise we'd paint the wrong
            // list under the now-active picker.
            guard activeSegment == segment else { return }
            reports = next
            status = next.isEmpty ? .empty : .loaded
        } catch let err as PostReportError {
            guard activeSegment == segment else { return }
            status = .error(err.errorDescription ?? "Couldn't load reports.")
        } catch {
            guard activeSegment == segment else { return }
            status = .error(error.localizedDescription)
        }
    }

    /// Soft-delete the reported post + mark the report actioned.
    /// Both calls land in sequence rather than as a transaction;
    /// partial failure (post deleted, report not yet marked) is
    /// recoverable on the next refresh — the post is gone for
    /// users either way.
    private func takeDown(_ report: Report) async {
        actionInFlight.insert(report.id)
        defer { actionInFlight.remove(report.id) }
        do {
            try await PostService().softDelete(postId: report.postId)
            try await PostReportService().markActioned(reportId: report.id)
            removeFromQueue(reportId: report.id)
            toastMessage = "Post taken down"
        } catch let err as PostReportError {
            toastMessage = err.errorDescription ?? "Couldn't action the report."
        } catch let err as PostError {
            toastMessage = err.errorDescription ?? "Couldn't take down the post."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func dismiss(_ report: Report) async {
        actionInFlight.insert(report.id)
        defer { actionInFlight.remove(report.id) }
        do {
            try await PostReportService().markDismissed(reportId: report.id)
            removeFromQueue(reportId: report.id)
            toastMessage = "Report dismissed"
        } catch let err as PostReportError {
            toastMessage = err.errorDescription ?? "Couldn't dismiss the report."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func removeFromQueue(reportId: String) {
        reports.removeAll { $0.id == reportId }
        if reports.isEmpty { status = .empty }
    }
}
