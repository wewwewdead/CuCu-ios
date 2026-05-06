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
///
/// The dismiss "X" is composed by the parent (e.g. the explore feed)
/// as a sibling of this view, **not** as a child. Nesting it inside a
/// surrounding `NavigationLink`'s label was swallowing the row's tap
/// because the inner `Button`'s hit area extended across the whole
/// top-trailing overlay region — this view stays purely the banner so
/// the navigation gesture has nothing to compete with.
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
    /// True when this card represents the signed-in user's own
    /// published profile. Drives a small "You" badge in the banner's
    /// top-leading corner so the user can pick their own card out
    /// of a feed of similar-looking templates without having to
    /// read every `@handle` first. Mirrors the puck on the explore
    /// title row — the two combine into a clear "this is you"
    /// affordance regardless of which entry the user spots first.
    var isOwn: Bool = false

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

    /// True only when the card has an actual image background to
    /// paint. Drives both the gradient/side-wash overlays (only
    /// rendered when there's a photo to compete with for legibility)
    /// and the text-color picks (dark ink on the default cream
    /// surface vs. cream on photo). Hex-only / seeded fallbacks count
    /// as "no image" — the user wanted those rows to land on the
    /// flat default cream surface, matching the reference's
    /// no-banner row treatment.
    private var hasImageBackground: Bool {
        if let url = resolvedBackgroundImageURL, !url.isEmpty { return true }
        return false
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
            // 44pt circle — render server-side at retina pixels so a
            // megapixel hero portrait doesn't cross the wire just to
            // sit in a banner thumbnail.
            if let urlString = resolvedAvatarImageURL,
               let url = CucuImageTransform.resized(urlString, square: 44) {
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
            .overlay(alignment: .topLeading) {
                if isOwn { ownBadge }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.8)
            )
    }

    /// "You" badge — refined cream-on-ink tag on the banner's
    /// top-leading edge. Drops the editorial mono-tracked label +
    /// rose chip in favour of a quiet bold sans label on a pure ink
    /// pill. Reads as identity (you are this card) without competing
    /// with the user's own banner art for attention.
    private var ownBadge: some View {
        Text("You")
            .font(.cucuSans(11, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .padding(10)
            .accessibilityLabel("Your profile")
    }

    // MARK: - Background layer

    @ViewBuilder
    private var backgroundLayer: some View {
        // Banner is full-width × 112pt — request server-side at the
        // typical iPad/iPhone column width so the renderer hands back
        // bytes proportional to the pixels actually painted, not the
        // multi-megapixel original.
        if let urlString = resolvedBackgroundImageURL,
           let url = CucuImageTransform.resized(urlString, width: 600, height: 112) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                defaultBackground
            }
        } else {
            // No image set — paint the flat default cream surface
            // and skip the seed/hex gradient entirely. Per design,
            // banners without a real photo all share one quiet
            // default look, with dark ink text on top.
            defaultBackground
        }
    }

    /// Default no-image surface. A soft cream tone consistent with
    /// the rest of the explore chrome so a photo-less profile reads
    /// as "no banner yet" rather than a mismatched coloured tile.
    private var defaultBackground: some View {
        Color.cucuPaperDeep
    }

    // MARK: - Gradient overlay (text contrast)

    /// Bottom-heavy gradient for legibility. Only rendered when the
    /// card has an actual photo behind it — flat cream cards don't
    /// need an overlay to read clearly. Opacities are intentionally
    /// gentle so the photo stays mostly visible (the previous tune
    /// blacked out the bottom half).
    @ViewBuilder
    private var gradientLayer: some View {
        if hasImageBackground {
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.05), location: 0.0),
                    .init(color: Color.black.opacity(0.22), location: 0.55),
                    .init(color: Color.black.opacity(0.45), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Left-side wash that biases contrast toward the text column.
    /// Same gating as `gradientLayer` — only paints when there's a
    /// photo behind the type. Reduced opacities so the photo on the
    /// right side reads naturally, with just enough wash on the
    /// leading edge to keep the display name legible.
    @ViewBuilder
    private var sideWashLayer: some View {
        if hasImageBackground {
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.05), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
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

    /// Display-name tone. Authored color when present; else adapts
    /// to the surface: cream ink on photo banners, dark ink on the
    /// flat default cream surface.
    private var displayNameColor: Color {
        if let hex = metadata?.displayNameColorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        if !hasImageBackground { return Color.cucuInk }
        return isBackgroundDark ? Color(hex: "#FBF9F2") : Color.white
    }

    private var bioColor: Color {
        if let hex = metadata?.bioColorHex, !hex.isEmpty {
            // Bio uses the authored color, but slightly desaturated
            // against the gradient — author's pick still reads as
            // their voice without overpowering the display name.
            return Color(hex: hex).opacity(0.92)
        }
        if !hasImageBackground { return Color.cucuInk.opacity(0.62) }
        return Color.white.opacity(0.88)
    }

    private var handleColor: Color {
        if !hasImageBackground { return Color.cucuInk.opacity(0.55) }
        // Cream-on-dark for photo banners — consistent across every
        // image card so users can scan @-tags without reparsing
        // tone each row.
        return Color.white.opacity(0.78)
    }

    private var textShadowColor: Color {
        // Subtle shadow guarantees readability when the gradient
        // alone isn't enough (e.g. a light pastel bg that decoded
        // its hex correctly but the bottom fade is still soft).
        // Skip on the flat default surface — no shadow on dark ink
        // over cream, it just smudges the type.
        if !hasImageBackground { return Color.clear }
        return Color.black.opacity(0.35)
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

    // MARK: - Seeded avatar tint

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
