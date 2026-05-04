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
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
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
        }
        .cucuSheetTitle("Moderation")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.cucuPaper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: segment) { _, _ in
            CucuHaptics.selection()
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
        .tint(Color.cucuInk)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - List

    private var reportsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(reports) { report in
                    reportCard(report)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func reportCard(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: report)

            // Body of the reported post — bordered card so it
            // reads as a quote rather than chrome text.
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(report.postAuthorUsername)")
                    .font(.cucuSerif(13, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Text(report.postBody.isEmpty ? "[post unavailable]" : report.postBody)
                    .font(.cucuSans(14))
                    .foregroundStyle(Color.cucuInk)
                    .lineLimit(4)
                    .truncationMode(.tail)
                Text(PostRowView.relativeTimestamp(for: report.createdAt))
                    .font(.cucuMono(11, weight: .regular))
                    .tracking(1.2)
                    .foregroundStyle(Color.cucuInkFaded)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cucuCardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.cucuInkRule, lineWidth: 1)
            )

            if let note = report.note, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
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
        .padding(14)
        .cucuCard(corner: 14, innerRule: true, elevation: .raised)
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
                    .font(.cucuMono(11, weight: .regular))
                    .tracking(1.2)
                    .foregroundStyle(Color.cucuInkFaded)
            }
            if let reviewedAt = report.reviewedAt {
                Text("· \(PostRowView.relativeTimestamp(for: reviewedAt))")
                    .font(.cucuMono(11, weight: .regular))
                    .tracking(1.2)
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer()
            viewThreadLink(rootId: report.postRootId)
        }
    }

    private func statusBadge(for status: ReportStatus) -> some View {
        let label: String
        let icon: String
        let text: Color
        let fill: Color
        let stroke: Color
        switch status {
        case .actioned:
            label = "Taken down"
            icon = "checkmark.shield"
            text = .cucuBurgundy
            fill = .cucuRose
            stroke = .cucuRoseStroke
        case .dismissed:
            label = "Dismissed"
            icon = "hand.thumbsdown"
            text = .cucuInkSoft
            fill = .cucuCardSoft
            stroke = .cucuInk.opacity(0.18)
        case .open:
            // Shouldn't appear in history, but render
            // defensively so a stale row from a race doesn't
            // crash.
            label = "Open"
            icon = "circle"
            text = .cucuBurgundy
            fill = .cucuRose
            stroke = .cucuRoseStroke
        }
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.cucuSerif(12, weight: .semibold))
        }
        .foregroundStyle(text)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
    }

    private func header(for report: Report) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                Image(systemName: reasonIcon(for: report.reason))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cucuInkSoft)
                Text(report.reason.displayLabel)
                    .font(.cucuSerif(14, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
            }
            Spacer()
            Text("via @\(report.reporterUsername)")
                .font(.cucuMono(11, weight: .regular))
                .tracking(1.2)
                .foregroundStyle(Color.cucuInkFaded)
        }
    }

    private func actionRow(for report: Report) -> some View {
        HStack(spacing: 8) {
            viewThreadLink(rootId: report.postRootId)
            Spacer()
            takeDownChip(report)
            dismissChip(report)
        }
    }

    /// Burgundy take-down chip — destructive action, gets the
    /// burgundy/rose palette so the moderator's eye lands on it
    /// before the neutral dismiss chip.
    private func takeDownChip(_ report: Report) -> some View {
        Button(role: .destructive) {
            CucuHaptics.delete()
            Task { await takeDown(report) }
        } label: {
            HStack(spacing: 5) {
                if actionInFlight.contains(report.id) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.cucuBurgundy)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Take down")
                        .font(.cucuSerif(13, weight: .semibold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.cucuBurgundy)
            .background(Capsule().fill(Color.cucuRose))
            .overlay(Capsule().strokeBorder(Color.cucuRoseStroke, lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(actionInFlight.contains(report.id))
    }

    /// Neutral dismiss chip — cucuCardSoft fill with a faint ink
    /// stroke so it reads as the secondary action.
    private func dismissChip(_ report: Report) -> some View {
        Button {
            Task { await dismiss(report) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Dismiss")
                    .font(.cucuSerif(13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.cucuInkSoft)
            .background(Capsule().fill(Color.cucuCardSoft))
            .overlay(Capsule().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(actionInFlight.contains(report.id))
    }

    /// Neutral chip wrapping a NavigationLink to the thread —
    /// matches the dismiss-chip palette so the row reads as
    /// "secondary actions" before the burgundy take-down chip.
    private func viewThreadLink(rootId: String) -> some View {
        NavigationLink {
            PostThreadView(rootId: rootId)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                Text("View thread")
                    .font(.cucuSerif(13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.cucuInkSoft)
            .background(Capsule().fill(Color.cucuCardSoft))
            .overlay(Capsule().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
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
                .tint(Color.cucuInkSoft)
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch segment {
        case .open:
            VStack(spacing: 14) {
                Spacer()
                CucuFleuronDivider()
                    .frame(maxWidth: 140)
                Text("All clear.")
                    .font(.cucuSerif(20, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text("No open reports right now.")
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
                Spacer()
            }
            .padding(.horizontal, 32)
        case .history:
            VStack(spacing: 14) {
                Spacer()
                CucuFleuronDivider()
                    .frame(maxWidth: 140)
                Text("Nothing reviewed yet.")
                    .font(.cucuSerif(20, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text("Reports you action or dismiss will show up here.")
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
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
                .foregroundStyle(Color.cucuBurgundy)
            Text("Couldn't load the queue")
                .font(.cucuSerif(18, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(message)
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            CucuChip("Try again", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
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
