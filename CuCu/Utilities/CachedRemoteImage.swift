import SwiftUI

/// SwiftUI wrapper for a remote image that funnels every fetch
/// through `CanvasImageLoader`. That gives us three things `AsyncImage`
/// alone doesn't:
///
///   1. **Cache sharing across the app** — the same `RemoteImageCache`
///      is used by gallery tiles in the canvas, the lightbox, and now
///      the full-gallery grid; tapping a tile that's already on
///      screen elsewhere paints instantly.
///   2. **Local-path fallback** — the loader transparently routes
///      `https://` to network and relative paths to
///      `LocalCanvasAssetStore`, so the same view works in editor
///      previews and the published viewer without branching.
///   3. **Off-screen frugality** — `LazyVGrid` only spawns visible
///      cells, so `.onAppear` only fires for tiles the user is
///      actually about to look at. Cells scrolled away don't fetch
///      and don't keep their bitmaps alive past `NSCache` eviction
///      pressure.
///
/// The placeholder is a soft cream rectangle while bytes load — same
/// `cucuCardSoft` used by other placeholders so the page reads
/// consistent during a slow network.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL
    let contentMode: ContentMode
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    /// Cached path string used to detect "the tile got rebound to a
    /// different URL while a fetch was in flight" — race-guard so a
    /// late callback doesn't paint stale bytes.
    @State private var loadingURLString: String?

    init(url: URL,
         contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping () -> Placeholder = { Color.cucuCardSoft }) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .onAppear { load(url: url) }
        .onChange(of: url) { _, newValue in load(url: newValue) }
    }

    private func load(url: URL) {
        let key = url.absoluteString
        loadingURLString = key

        if let cached = CanvasImageLoader.loadSync(key) {
            image = cached
            return
        }
        // Cache miss — clear stale bitmap (e.g. when a tile gets
        // rebound to a different URL) and start the async fetch.
        image = nil
        CanvasImageLoader.loadAsync(key) { fetched in
            // Drop stale completions: the cell's URL may have
            // changed mid-flight if the parent recycled it.
            guard loadingURLString == key, let fetched else { return }
            image = fetched
        }
    }
}
