import SwiftUI

/// One profile rendered as a wide preview banner — the explore feed's
/// primary card. Composition mirrors the user's hero on a small scale:
///
///   1. **Background.** Page-background image (when set) or the page's
///      hex tone, cropped to a 16:7 banner. Falls back to a tinted
///      gradient seeded by the username so a profile that hasn't
///      uploaded a banner still reads as theirs.
///   2. **Gradient overlay.** A bottom-heavy linear gradient between a
///      transparent top and an ink-side stop, tuned per
///      bg-luminance: dark backgrounds get a charcoal-fade so the
///      light text on top still has contrast; light backgrounds get a
///      cream-with-ink-shadow combo.
///   3. **Hero copy.** Display name in the user's hero font + color.
///      Bio truncated to two lines. Both fall back to deterministic
///      values (username for name, "Tap to peek inside ✦" for bio)
///      when the publish step hasn't surfaced metadata yet.
///   4. **Avatar tile.** Small circular thumbnail to the left of the
///      banner — gives a stable identity beat next to the banner's
///      varying tone.
///   5. **Close button.** Top-right "X" mirrors the screenshot's
///      dismiss affordance; passes through to the `onDismiss` arg so
///      the host can collapse / hide the row.
struct PreviewBannerCard: View {
    let profile: PublishedProfileSummary
    /// Late-binding override sourced from the explore feed's
    /// `fetchBackgrounds(for:)` enrichment. When present, it takes
    /// precedence over `profile.cardMetadata?.backgroundImageURL` /
    /// `backgroundHex` — the metadata column is the long-term path,
    /// the override is what ships **today** without a SQL migration.
    var backgroundImageURLOverride: String? = nil
    var backgroundHexOverride: String? = nil
    /// Late-binding avatar URL pulled by the explore feed's
    /// `fetchBackgrounds` enrichment from each profile's
    /// `design_json.heroAvatarURL`. Takes precedence over
    /// `cardMetadata?.avatarImageURL` (the long-term column path)
    /// and lets the banner show the user's actual hero avatar
    /// instead of falling through to the initial-letter chip.
    var avatarImageURLOverride: String? = nil
    var onDismiss: (() -> Void)? = nil

    private var metadata: PublishedProfileCardMetadata? { profile.cardMetadata }

    private var resolvedAvatarImageURL: String? {
        if let url = avatarImageURLOverride, !url.isEmpty { return url }
        return metadata?.avatarImageURL
    }

    private var resolvedBackgroundImageURL: String? {
        if let url = backgroundImageURLOverride, !url.isEmpty { return url }
        return metadata?.backgroundImageURL
    }

    private var resolvedBackgroundHex: String? {
        if let hex = backgroundHexOverride, !hex.isEmpty { return hex }
        return metadata?.backgroundHex
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarTile
            bannerSurface
        }
    }

    // MARK: - Avatar tile

    private var avatarTile: some View {
        ZStack {
            Circle().fill(seedTint(saturation: 0.45, luminance: 0.86))
            // Only the hero's `.profileAvatar` image qualifies as the
            // banner's avatar — `profile.thumbnailURL` is the whole-
            // canvas snapshot (a tiny render of the entire page) and
            // using it here leaked the page composite into the
            // identity slot. Resolution order: late-binding override
            // (from `fetchBackgrounds`'s `heroAvatarURL` enrichment) →
            // long-term column path (`cardMetadata.avatarImageURL`) →
            // initial-letter chip.
            if let urlString = resolvedAvatarImageURL,
               !urlString.isEmpty,
               let url = URL(string: urlString) {
                CachedRemoteImage(url: url, contentMode: .fill) {
                    avatarFallback
                }
                .clipShape(Circle())
            } else {
                avatarFallback
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
        )
        .shadow(color: Color.cucuInk.opacity(0.10), radius: 2, x: 0, y: 1)
    }

    private var avatarFallback: some View {
        Text(initialLetter)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.cucuBurgundy)
    }

    // MARK: - Banner surface

    private var bannerSurface: some View {
        // Content view drives the ZStack's intrinsic size; bg image
        // and gradients live in `.background(...)` so the image's
        // own aspect ratio doesn't blow out the frame the typography
        // is laid out against. Without this, `.aspectRatio(.fill)`
        // on the remote image grew the ZStack beyond the 112pt
        // frame and the type slid outside the visible band.
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: 112)
            // `.background` adds a layer *behind* the current view,
            // so the visible stack reads bottom-to-top from the
            // outermost call inward: backgroundLayer (deepest) →
            // gradient → side wash → content.
            .background { sideWashLayer }
            .background { gradientLayer }
            .background { backgroundLayer }
            .compositingGroup()
            .overlay(alignment: .topTrailing) {
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide \(profile.username)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.cucuInk.opacity(0.10), radius: 6, x: 0, y: 3)
    }

    // MARK: - Background layer

    @ViewBuilder
    private var backgroundLayer: some View {
        if let urlString = resolvedBackgroundImageURL,
           let url = URL(string: urlString),
           !urlString.isEmpty {
            CachedRemoteImage(url: url, contentMode: .fill) {
                hexOrGradientBackground
            }
        } else {
            // Deliberately don't fall through to `thumbnailURL` here —
            // that's the whole-canvas snapshot (mostly empty cream
            // space at the bottom), which crops poorly into a wide
            // banner. The seed gradient gives every metadata-less
            // profile a distinct themed surface that the type sits
            // over cleanly.
            hexOrGradientBackground
        }
    }

    /// Solid color → linear two-tone if the profile carries a hex,
    /// else a deterministic seeded gradient so every empty profile
    /// still reads as a different banner.
    @ViewBuilder
    private var hexOrGradientBackground: some View {
        if let hex = resolvedBackgroundHex, !hex.isEmpty {
            let base = Color(hex: hex)
            LinearGradient(
                colors: [base, base.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            seedGradient
        }
    }

    // MARK: - Gradient overlay (text contrast)

    /// Bottom-heavy gradient that always fades to an *ink* stop where
    /// the text sits, regardless of bg luminance. The screenshot's
    /// cards do this same trick — light pastel banners still get a
    /// dark fade at the bottom so the white display name reads
    /// cleanly. We tune the top of the gradient by luminance: darker
    /// backgrounds get a transparent top (no need to dim further),
    /// lighter backgrounds get a faint ink wash so the text isn't
    /// floating on a pure pastel.
    @ViewBuilder
    private var gradientLayer: some View {
        let darkBg = isBackgroundDark
        // Top: faint wash so the display name reads on bright photo
        // bands (e.g. a sky in the upper third).
        // Mid: drop quickly to a denser stop ~50% — that's where the
        //   handle sits and where most photo subjects also land.
        // Bottom: a near-opaque ink stop under the bio so even a
        //   high-contrast lower band can't beat the type.
        let topOpacity: Double = darkBg ? 0.20 : 0.30
        let midOpacity: Double = darkBg ? 0.55 : 0.62
        let bottomOpacity: Double = darkBg ? 0.92 : 0.86
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(topOpacity), location: 0.0),
                .init(color: Color.black.opacity(midOpacity), location: 0.50),
                .init(color: Color.black.opacity(bottomOpacity), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Left-side wash that biases contrast toward the text column.
    /// The display name + bio sit on the leading edge, so a horizontal
    /// gradient from a deeper-on-left stop to transparent on the right
    /// keeps the right side of the banner photographically clean while
    /// the typography on the left has its own contrast budget.
    private var sideWashLayer: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.55), Color.black.opacity(0.10), Color.clear],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            displayNameView
            handleView
                .padding(.top, 1)
            Spacer(minLength: 4)
            bioView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayNameView: some View {
        Text(displayNameText)
            .font(displayNameFont)
            .foregroundStyle(displayNameColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .shadow(color: textShadowColor, radius: 1.4, x: 0, y: 1)
    }

    private var handleView: some View {
        Text("@\(profile.username)")
            .font(.cucuSans(11, weight: .medium))
            .foregroundStyle(handleColor)
            .lineLimit(1)
    }

    private var bioView: some View {
        Text(bioText)
            .font(bioFont)
            .foregroundStyle(bioColor)
            .lineLimit(2)
            .truncationMode(.tail)
            .shadow(color: textShadowColor, radius: 1.0, x: 0, y: 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Resolved text

    private var displayNameText: String {
        if let n = metadata?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { return n }
        // No surfaced display name — capitalize the username so it
        // still reads like a name instead of a handle. "primeghiblistudio"
        // becomes "Primeghiblistudio"; not perfect, but a sensible
        // first-paint until the metadata column lands.
        return profile.username.prefix(1).uppercased() + profile.username.dropFirst()
    }

    private var bioText: String {
        if let raw = metadata?.bio?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            // Collapse runs of whitespace / newlines so the two-line
            // banner still gets two distinct lines of content from a
            // bio the author wrote with line breaks.
            let collapsed = raw
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
            return collapsed
        }
        return "Tap to peek inside ✦"
    }

    // MARK: - Resolved fonts

    private var displayNameFont: Font {
        let family = resolvedFamily(metadata?.displayNameFontKey) ?? .fraunces
        return family.swiftUIFont(size: 19, weight: .bold)
    }

    private var bioFont: Font {
        let family = resolvedFamily(metadata?.bioFontKey) ?? .system
        return family.swiftUIFont(size: 13, weight: .regular)
    }

    private func resolvedFamily(_ raw: String?) -> NodeFontFamily? {
        guard let raw, !raw.isEmpty else { return nil }
        return NodeFontFamily(rawValue: raw)
    }

    // MARK: - Resolved colors

    /// Display-name tone. Authored color when present; else the
    /// adaptive light-on-dark / dark-on-light pick that matches the
    /// hero's `applyAdaptiveHeroTextColors` math.
    private var displayNameColor: Color {
        if let hex = metadata?.displayNameColorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return isBackgroundDark ? Color(hex: "#FBF9F2") : Color.white
    }

    private var bioColor: Color {
        if let hex = metadata?.bioColorHex, !hex.isEmpty {
            // Bio uses the authored color, but slightly desaturated
            // against the gradient — author's pick still reads as
            // their voice without overpowering the display name.
            return Color(hex: hex).opacity(0.92)
        }
        return Color.white.opacity(0.88)
    }

    private var handleColor: Color {
        // Always cream-on-dark — the handle is consistent across
        // every card so users can scan @-tags without reparsing the
        // banner's tone each row.
        Color.white.opacity(0.78)
    }

    private var textShadowColor: Color {
        // Subtle shadow guarantees readability when the gradient
        // alone isn't enough (e.g. a light pastel bg that decoded
        // its hex correctly but the bottom fade is still soft).
        Color.black.opacity(0.35)
    }

    // MARK: - Background luminance

    /// True when the resolved background reads dark. Image-backed
    /// cards default to "dark" because we don't have the luminance
    /// cache available from the explore feed — the gradient overlay
    /// covers either case acceptably, so the false-positive cost is
    /// only a slightly-lighter handle color on a light-photo banner.
    private var isBackgroundDark: Bool {
        if let url = resolvedBackgroundImageURL, !url.isEmpty { return true }
        if let hex = resolvedBackgroundHex, !hex.isEmpty {
            return Self.hexLuminance(hex) < 0.5
        }
        // Seed gradient is mid-tone — call it dark for contrast.
        return true
    }

    private static func hexLuminance(_ hex: String) -> Double {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count >= 6,
              let value = UInt32(trimmed.prefix(6), radix: 16) else { return 0 }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Seeded fallback gradient

    /// Hash the username into the cucu palette so empty-banner cards
    /// still differentiate. Three-stop gradient gives the card a bit
    /// of motion across the wide aspect — closer to the screenshot's
    /// vibe than a flat fill.
    private var seedGradient: LinearGradient {
        let palette: [(Color, Color)] = [
            (.cucuBurgundy, .cucuRose),
            (.cucuMidnight, .cucuCobalt),
            (.cucuMoss, .cucuMatcha),
            (.cucuCherry, .cucuShell),
            (.cucuInk, .cucuInkSoft),
            (Color(hex: "#5C3A8A"), Color(hex: "#A88FCB")),
            (Color(hex: "#1F4F4A"), Color(hex: "#A8C4B5")),
            (Color(hex: "#7A2A4D"), Color(hex: "#E8B0C0")),
        ]
        let pair = palette[abs(seedHash) % palette.count]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func seedTint(saturation: Double, luminance: Double) -> Color {
        let h = Double(abs(seedHash) % 360) / 360
        return Color(hue: h, saturation: saturation, brightness: luminance)
    }

    private var seedHash: Int {
        profile.username.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 131 }
    }

    private var initialLetter: String {
        guard let first = profile.username.first else { return "?" }
        return String(first).uppercased()
    }
}
