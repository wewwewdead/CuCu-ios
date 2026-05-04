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
            Button("More Options") {
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
        VStack(spacing: 8) {
            Text("Share your CuCu profile")
                .font(.cucuSans(30, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text("Post your profile card or send your profile path.")
                .font(.callout)
                .foregroundStyle(Color.cucuInkFaded)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var cardPreviewSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.cucuCard)
                    .shadow(color: Color.cucuInk.opacity(0.12), radius: 18, x: 0, y: 10)

                cardPreviewContent
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(10)
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxHeight: 430)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.12), lineWidth: 1)
            )

            Text("Use Share Profile Card for Instagram, Facebook, TikTok, and Stories.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if showsPageOneNotice {
                Text("Sharing page 1 of your profile.")
                    .font(.footnote.weight(.semibold))
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
                Text("Making your profile card…")
                    .font(.cucuSans(15, weight: .semibold))
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
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.cucuBurgundy)
                Text("Card preview unavailable")
                    .font(.cucuSans(16, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text("You can still share your profile path.")
                    .font(.footnote)
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
            colors: [Color.cucuRose.opacity(0.55), Color.cucuSky.opacity(0.75), Color.cucuMossSoft.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var identityCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cucuRose)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.cucuBurgundy)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(normalizedUsername)")
                        .font(.cucuSans(18, weight: .bold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(profilePath)
                        .font(.cucuMono(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color.cucuCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.12), lineWidth: 1)
        )
    }

    private var platformHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.top, 2)
            Text("The iOS share sheet opens next. You choose the final app and whether to post, send, or save.")
                .font(.footnote)
                .foregroundStyle(Color.cucuInkFaded)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.cucuCardSoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    Text(isSharingCard || isGeneratingCard ? "Preparing Card…" : "Share Profile Card")
                }
                .font(.cucuSans(17, weight: .bold))
                .foregroundStyle(Color.cucuCard)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.cucuInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)
            .opacity(actionsDisabled ? 0.70 : 1)

            Button {
                copyPath()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                    Text(copiedPath ? "Copied" : "Copy Profile Path")
                }
                .font(.cucuSans(16, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.cucuCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)

            Button {
                sharePathOnly()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("More Options")
                }
                .font(.cucuSans(15, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
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
                ?? "Couldn't make the profile card right now."
            cardState = .failed(message)
            if showErrorOnFailure {
                shareErrorMessage = "\(message) You can still use More Options to share \(profilePath)."
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
