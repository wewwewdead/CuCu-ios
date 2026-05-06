import SwiftUI
import UIKit

struct ProfileShareSheet: View {
    let username: String
    let document: ProfileDocument?

    @Environment(\.dismiss) private var dismiss
    @State private var cardState: ShareCardState = .idle
    @State private var activityPayload: ShareActivityPayload?
    @State private var isSharingCard = false
    @State private var copiedPath = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var shareErrorMessage: String?

    private var normalizedUsername: String {
        ProfileShareLink.normalizedUsername(username)
    }

    private var profilePath: String {
        ProfileShareLink.path(username: username)
    }

    private var isGeneratingCard: Bool {
        if case .loading = cardState { return true }
        return false
    }

    private var actionsDisabled: Bool {
        isGeneratingCard || isSharingCard
    }

    private var pageCount: Int {
        document?.pages.count ?? 0
    }

    private var showsPageOneNotice: Bool {
        pageCount > 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    cardPreviewSection
                    identityCard
                    platformHint
                    actionStack
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(Color.cucuPaper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.cucuInk)
                            .frame(width: 30, height: 30)
                            .background(Color.cucuCard, in: Circle())
                            .overlay(Circle().strokeBorder(Color.cucuInk.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close share sheet")
                }
            }
        }
        .task(id: normalizedUsername) {
            await generatePreviewIfNeeded()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
        .sheet(item: $activityPayload) { payload in
            ShareSheetView(activityItems: payload.items) {
                activityPayload = nil
            }
        }
        .alert(
            "Share card unavailable",
            isPresented: Binding(
                get: { shareErrorMessage != nil },
                set: { if !$0 { shareErrorMessage = nil } }
            )
        ) {
            Button("Send the link instead") {
                shareErrorMessage = nil
                sharePathOnly()
            }
            Button("OK", role: .cancel) {
                shareErrorMessage = nil
            }
        } message: {
            Text(shareErrorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Share your CuCu")
                .font(.cucuSerif(32, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text("Post your vibe — friends tap and they're in.")
                .font(.cucuEditorial(15, italic: true))
                .foregroundStyle(Color.cucuInkFaded)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var cardPreviewSection: some View {
        VStack(spacing: 12) {
            // 2:3 portrait matches the renderer's output (1080×1620). The
            // preview frame is intentionally restrained — a thin warm
            // matte and a hairline border, not a glossy tile — so the
            // card itself does the visual heavy lifting.
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.cucuCard)
                    .shadow(color: Color.cucuInk.opacity(0.10), radius: 22, x: 0, y: 14)

                cardPreviewContent
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(8)
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxHeight: 460)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 1)
            )

            Text("Looks right at home in Stories, TikTok, and DMs.")
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if showsPageOneNotice {
                Text("Sharing page one of your CuCu.")
                    .font(.cucuSans(12, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var cardPreviewContent: some View {
        switch cardState {
        case .idle, .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Polishing your CuCu…")
                    .font(.cucuEditorial(14, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(previewPlaceholderBackground)

        case .ready(let image):
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.cucuBurgundy.opacity(0.85))
                Text("Card preview unavailable")
                    .font(.cucuSerif(16, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text("You can still share your link.")
                    .font(.cucuEditorial(13, italic: true))
                    .foregroundStyle(Color.cucuInkFaded)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(previewPlaceholderBackground)
        }
    }

    private var previewPlaceholderBackground: some View {
        LinearGradient(
            colors: [Color.cucuPaper, Color.cucuPaperDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var identityCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.cucuRose)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.cucuBurgundy)
            }
            .frame(width: 46, height: 46)
            .overlay(Circle().strokeBorder(Color.cucuInk.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(normalizedUsername)")
                    .font(.cucuSerif(20, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(profilePath)
                    .font(.cucuMono(13, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.cucuCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 1)
        )
    }

    private var platformHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.top, 3)
            Text("Pick where it lands next — Story, post, DM, save.")
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkFaded)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.cucuCardSoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionStack: some View {
        VStack(spacing: 10) {
            Button {
                Task { await shareProfileCard() }
            } label: {
                HStack(spacing: 10) {
                    if isSharingCard || isGeneratingCard {
                        ProgressView()
                            .tint(Color.cucuCard)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isSharingCard || isGeneratingCard ? "Polishing your CuCu…" : "Share my CuCu")
                }
                .font(.cucuSans(17, weight: .bold))
                .foregroundStyle(Color.cucuCard)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Capsule().fill(Color.cucuInk))
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)
            .opacity(actionsDisabled ? 0.70 : 1)

            Button {
                copyPath()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: copiedPath ? "checkmark" : "link")
                    Text(copiedPath ? "Copied" : "Copy link")
                }
                .font(.cucuSans(16, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(Color.cucuCard))
                .overlay(Capsule().strokeBorder(Color.cucuInk.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)

            Button {
                sharePathOnly()
            } label: {
                Text("Just send the link")
                    .font(.cucuSans(13, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)
        }
    }

    private func generatePreviewIfNeeded() async {
        guard case .idle = cardState else { return }
        await generateCard(showErrorOnFailure: false)
    }

    private func shareProfileCard() async {
        if case .ready(let image) = cardState {
            presentShareSheet(with: image)
            return
        }

        isSharingCard = true
        await generateCard(showErrorOnFailure: true)
        if case .ready(let image) = cardState {
            presentShareSheet(with: image)
        }
        isSharingCard = false
    }

    private func generateCard(showErrorOnFailure: Bool) async {
        cardState = .loading
        do {
            let image = try await ProfileShareCardRenderer.render(
                username: username,
                profileLink: profilePath,
                document: document
            )
            cardState = .ready(image)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't make your CuCu card right now."
            cardState = .failed(message)
            if showErrorOnFailure {
                shareErrorMessage = "\(message) You can still send \(profilePath)."
            }
        }
    }

    private func presentShareSheet(with image: UIImage) {
        activityPayload = ShareActivityPayload(items: [
            image,
            ProfileShareLink.activityItem(username: username),
        ])
    }

    private func copyPath() {
        UIPasteboard.general.string = profilePath
        CucuHaptics.success()
        copiedPath = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                copiedPath = false
            }
        }
    }

    private func sharePathOnly() {
        activityPayload = ShareActivityPayload(items: [ProfileShareLink.activityItem(username: username)])
    }
}

private enum ShareCardState {
    case idle
    case loading
    case ready(UIImage)
    case failed(String)
}

private struct ShareActivityPayload: Identifiable {
    let id = UUID()
    let items: [Any]
}
