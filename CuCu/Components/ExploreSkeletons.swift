import SwiftUI

/// Skeleton placeholders shown on the explore feed before the first
/// fetch returns. Designed to match the real card geometry exactly so
/// the layout doesn't jump when the data lands — the user perceives
/// the page as "structurally there, content arriving" rather than
/// "blank, then suddenly populated."
///
/// All skeletons use `CucuShimmerModifier` for a subtle traveling-
/// highlight effect. The shimmer is one continuous gradient sweep
/// per ~1.4s, looped, so on a slow network a user reading the
/// chrome above sees a calm, premium "loading" tell rather than a
/// stuttering ProgressView.

// MARK: - Shimmer

/// Animated highlight overlay drawn over the skeleton's fill. Each
/// skeleton is already opaque + clipped to its own rounded rect, so
/// the overlay needs no extra mask — it inherits the parent's
/// effective clipping when SwiftUI rasterizes the layer.
private struct CucuShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.0
    var active: Bool = true

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { proxy in
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0), location: 0.30),
                            .init(color: .white.opacity(0.28), location: 0.50),
                            .init(color: .white.opacity(0.0), location: 0.70),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: proxy.size.width * 1.6)
                    .offset(x: phase * proxy.size.width * 1.4)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}

extension View {
    /// Shimmer-tint a skeleton view. Drives the highlight via
    /// `CucuShimmerModifier`; the modifier masks itself to the
    /// caller's shape so the highlight never leaks past the
    /// skeleton's outline.
    func cucuShimmer(active: Bool = true) -> some View {
        modifier(CucuShimmerModifier(active: active))
    }
}

// MARK: - Banner card skeleton

/// Skeleton for one row of the explore column. Mirrors the real
/// `PreviewBannerCard` geometry exactly — same avatar tile + 112pt
/// banner with the same corner radii — so the column doesn't
/// reflow when the data lands. Shimmer is applied per-shape so the
/// highlight is naturally clipped by each `.clipShape` rather than
/// leaking past the row's bounding box.
struct BannerCardSkeleton: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(Color.cucuCardSoft)
                .frame(width: 44, height: 44)
                .cucuShimmer()
                .clipShape(Circle())

            bannerRect
        }
    }

    private var bannerRect: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.cucuCardSoft)

            // Faux display-name + handle + bio bars give the
            // shimmer something to lift, vs a flat panel which
            // reads "stalled image" rather than "loading."
            // Bars use the deeper paper tone so the shimmer pass
            // doesn't wash them into the surrounding fill.
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cucuInkFaded.opacity(0.45))
                    .frame(width: 130, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cucuInkFaded.opacity(0.30))
                    .frame(width: 70, height: 8)
                Spacer().frame(height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cucuInkFaded.opacity(0.40))
                    .frame(width: 180, height: 9)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(height: 112)
        .cucuShimmer()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 0.8)
        )
    }
}

// MARK: - Top pick tile skeleton

/// Skeleton for one Top This Week carousel tile. 196×96 — same as
/// the real tile so the carousel's content size matches the loaded
/// state and the scroll position doesn't snap when data lands.
struct TopPickTileSkeleton: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.cucuCardSoft)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cucuInkFaded.opacity(0.45))
                    .frame(width: 100, height: 11)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cucuInkFaded.opacity(0.30))
                    .frame(width: 60, height: 7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 196, height: 96)
        .cucuShimmer()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 0.8)
        )
    }
}
