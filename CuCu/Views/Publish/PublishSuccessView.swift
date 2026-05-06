import SwiftUI

/// Cute, share-forward success surface that replaces the previous
/// generic green-check + four-pills layout. The visual goal is
/// rewarding, shareable, and product-coherent — the user just made
/// something public, and the screen should feel like a small
/// celebration, then immediately point at sharing.
///
/// Pulled out of `PublishSheet` so the heavy layout doesn't bloat
/// the parent file's body and so the success surface can be reused
/// from anywhere else that wants to celebrate a publish (e.g., a
/// future deep-link "I just republished" toast).
///
/// **Data sources:**
///   - `result.username` — drives the path label and identity card
///   - `document` — pulled in-memory from the current draft so the
///     preview card mirrors the user's actual avatar / display name
///     without any network call. Cleared at sheet dismiss along with
///     the rest of `PublishSheet`'s state.
struct PublishSuccessView: View {
    let result: PublishedProfileResult
    let document: ProfileDocument
    let onShare: () -> Void
    let onView: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void

    @State private var chrome = AppChromeStore.shared

    @State private var headlineVisible = false
    @State private var cardVisible = false
    @State private var actionsVisible = false
    @State private var sparkleRotation: Double = -16

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 24)
                badge
                headline
                previewCard
                actions
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            CucuHaptics.success()
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.05)) {
                sparkleRotation = 8
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.1)) {
                headlineVisible = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.22)) {
                cardVisible = true
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.84).delay(0.36)) {
                actionsVisible = true
            }
        }
    }

    // MARK: - Badge

    private var badge: some View {
        ZStack {
            Circle()
                .fill(chrome.theme.cardColor)
                .frame(width: 92, height: 92)
                .overlay(Circle().strokeBorder(chrome.theme.inkPrimary, lineWidth: 1.5))
                .shadow(color: chrome.theme.inkPrimary.opacity(0.08), radius: 12, x: 0, y: 6)

            // The sparkle does the heavy lifting visually — bigger
            // than the old green check and themed against the chrome
            // ink so it feels in-system, not a generic OS glyph.
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .rotationEffect(.degrees(sparkleRotation))
        }
        .scaleEffect(headlineVisible ? 1 : 0.7)
        .opacity(headlineVisible ? 1 : 0)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(spacing: 6) {
            Text("Your CuCu is live")
                .font(.cucuSerif(28, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .multilineTextAlignment(.center)

            Text("Post your vibe — anyone with the link can visit.")
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .opacity(headlineVisible ? 1 : 0)
        .offset(y: headlineVisible ? 0 : 6)
    }

    // MARK: - Preview card

    /// Compact identity card the user is about to share. Mirrors the
    /// share-image card's vocabulary so the user previews "what goes
    /// out" before tapping the share action — same avatar, same name,
    /// same handle. Renders directly from the in-memory document, so
    /// it's offline-safe and stays in lockstep with whatever Quick
    /// Edit / canvas changes preceded this publish.
    private var previewCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                avatarView
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .overlay(Circle().strokeBorder(chrome.theme.inkPrimary.opacity(0.10), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.cucuSerif(18, weight: .bold))
                        .foregroundStyle(chrome.theme.cardInkPrimary)
                        .lineLimit(1)
                    Text("@\(result.username)")
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.cardInkFaded)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider().background(chrome.theme.rule)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.theme.cardInkFaded)
                Text(ProfileShareLink.linkString(username: result.username))
                    .font(.cucuMono(12, weight: .medium))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            // Tiny footer mirrors the share-card wordmark so the preview the
            // user sees here uses the same vocabulary as the artifact they
            // actually post — quiet, editorial, never an ad.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded.opacity(0.72))
                Text("Made with CuCu")
                    .font(.cucuEditorial(11, italic: true))
                    .foregroundStyle(chrome.theme.cardInkFaded.opacity(0.85))
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded.opacity(0.72))
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(chrome.theme.cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(chrome.theme.rule, lineWidth: 1)
        )
        .opacity(cardVisible ? 1 : 0)
        .offset(y: cardVisible ? 0 : 14)
        .scaleEffect(cardVisible ? 1 : 0.96)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let path = avatarPath, let url = LocalCanvasAssetStore.resolveURL(path),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                chrome.theme.pageColor
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded)
            }
        }
    }

    private var displayName: String {
        if let id = StructuredProfileLayout.roleID(.profileName, in: document),
           let text = document.nodes[id]?.content.text,
           !text.isEmpty {
            return text
        }
        return "@\(result.username)"
    }

    private var avatarPath: String? {
        guard let id = StructuredProfileLayout.roleID(.profileAvatar, in: document) else { return nil }
        return document.nodes[id]?.content.localImagePath
    }

    // MARK: - Actions

    /// Two-tier action stack. Share is the primary because the entire
    /// growth loop hinges on the user's first share; View / Copy /
    /// Done are secondary affordances. The previous design treated
    /// all four as equal pills, which buried the most important one.
    private var actions: some View {
        VStack(spacing: 10) {
            primaryShareButton

            HStack(spacing: 10) {
                secondaryButton(title: "View", systemImage: "eye", action: onView)
                secondaryButton(title: "Copy", systemImage: "link", action: onCopy)
            }

            Button("Done", action: onDone)
                .font(.cucuSans(13, weight: .medium))
                .foregroundStyle(chrome.theme.inkFaded)
                .padding(.top, 4)
                .buttonStyle(.plain)
        }
        .opacity(actionsVisible ? 1 : 0)
        .offset(y: actionsVisible ? 0 : 12)
    }

    private var primaryShareButton: some View {
        Button(action: onShare) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                Text("Share my CuCu")
                    .font(.cucuSans(16, weight: .bold))
            }
            .foregroundStyle(chrome.theme.pageColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(chrome.theme.inkPrimary))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.cucuSans(14, weight: .semibold))
            }
            .foregroundStyle(chrome.theme.inkPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(chrome.theme.cardColor)
            )
            .overlay(
                Capsule().strokeBorder(chrome.theme.rule, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
