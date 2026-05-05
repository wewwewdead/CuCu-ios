import Foundation

/// Server-side image resize for Supabase Storage URLs.
///
/// Supabase exposes two ways to fetch a stored object:
///   - `…/storage/v1/object/public/<bucket>/<path>`     — the raw upload
///   - `…/storage/v1/render/image/public/<bucket>/<path>?width=…&…`
///     — the transformed variant, served by the edge image renderer
///
/// CuCu writes the *raw* upload URL into `design_json` (avatars,
/// page backgrounds, gallery tiles, thumbnails). At render time most
/// of those bytes are wasted: a 2000×2000 hero avatar paints into a
/// 40×40 row tile. Rewriting the URL through the renderer cuts the
/// download to the displayed pixel count, which is typically a
/// 50–100× saving for avatars and a 5–10× saving for banners.
///
/// The rewrite is **opportunistic**:
///   - Foreign URLs (anything that doesn't match the Supabase Storage
///     pattern) pass through unchanged so external image hosts and
///     `bundled:` placeholders aren't rerouted into a 404.
///   - URLs that already use the renderer endpoint pass through
///     unchanged so a downstream caller can override the size without
///     stacking transforms.
///   - Local file URLs and non-https schemes are returned untouched.
///
/// Behaviour preserved: the URL written to `design_json` (and stored
/// in the `RemoteImageCache` keyed off `URL.absoluteString`) is
/// distinct per requested size, so a 40×40 row avatar and a 200×200
/// expanded view of the same image are cached as separate entries —
/// each rendered at its own displayed pixel count.
enum CucuImageTransform {
    /// Master switch for the URL rewrite. **Off by default** because
    /// the `/storage/v1/render/image/public/...` renderer endpoint
    /// is a Supabase Pro-plan-and-above feature — on the free tier
    /// it returns 400/404 and every avatar / banner load fails.
    /// Flip this on (or read it from a config file / build setting)
    /// once you've confirmed your project has Image Transformations
    /// enabled. Off, every `resized(...)` call returns the input URL
    /// unchanged so the rest of the app keeps working.
    ///
    /// The helper still exists when disabled because:
    ///   1. Call sites pre-route every image URL through here, so
    ///      flipping the flag re-engages every transform without
    ///      another sweep of the codebase.
    ///   2. Future feature gates (different sizes per tier, on-device
    ///      pre-resize fallback) would slot in here cleanly.
    static var isEnabled: Bool = false

    /// Rewrite a Supabase Storage public-object URL through the
    /// image renderer at the requested pixel size. The size is the
    /// *render* target, not the display point — call sites pass
    /// `pointSize × scale` so retina pixel density is preserved.
    ///
    /// `resize: .cover` (the default) crops to fill the requested box
    /// without distortion — the right pick for square avatar tiles
    /// and edge-to-edge banner cards. Use `.contain` for cases that
    /// must show the whole image (lightboxes, full-canvas previews)
    /// — but those typically want full resolution, so most callers
    /// shouldn't pass a size hint at all there.
    static func resized(
        _ url: URL,
        width: Int,
        height: Int,
        resize: ResizeMode = .cover
    ) -> URL {
        // Disabled → pass through. The helper stays a no-op so call
        // sites stay declarative and a future enable flips every
        // transform back on at once.
        guard isEnabled else { return url }
        guard width > 0, height > 0 else { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              host.hasSuffix(".supabase.co") || host.hasSuffix(".supabase.in") else {
            return url
        }

        let path = components.path
        // Already on the renderer — let the existing query string
        // win so a caller that pre-sized stays in control.
        if path.hasPrefix("/storage/v1/render/image/public/") {
            return url
        }
        // Only rewrite the public-object path. Signed-URL endpoints
        // and other variants are left alone — they have their own
        // render counterparts but aren't used by CuCu's read paths.
        let publicPrefix = "/storage/v1/object/public/"
        guard path.hasPrefix(publicPrefix) else {
            return url
        }

        var rewritten = components
        rewritten.path = "/storage/v1/render/image/public/" +
            String(path.dropFirst(publicPrefix.count))

        var items = rewritten.queryItems ?? []
        // Drop any pre-existing width/height/resize params so a
        // caller's size hint always wins. Keep unrelated params (a
        // future signing token, etc.) so the rewrite doesn't strip
        // information out of the URL.
        let reserved: Set<String> = ["width", "height", "resize", "quality"]
        items.removeAll { reserved.contains($0.name) }
        items.append(URLQueryItem(name: "width", value: String(width)))
        items.append(URLQueryItem(name: "height", value: String(height)))
        items.append(URLQueryItem(name: "resize", value: resize.rawValue))
        rewritten.queryItems = items

        return rewritten.url ?? url
    }

    /// Convenience for square targets — most CuCu use cases.
    /// `points` is the SwiftUI / UIKit point size; the helper
    /// multiplies by the screen scale to request a retina-correct
    /// pixel count without the call site having to remember.
    static func resized(_ url: URL, square points: CGFloat, resize: ResizeMode = .cover) -> URL {
        let scaled = max(1, Int((points * Self.scale).rounded()))
        return resized(url, width: scaled, height: scaled, resize: resize)
    }

    /// Same as `resized(_:square:)` but takes a string URL — common
    /// in CuCu where avatar URLs sit inside `design_json` as text.
    /// Returns nil iff the input doesn't parse as a URL.
    static func resized(_ urlString: String, square points: CGFloat, resize: ResizeMode = .cover) -> URL? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        return resized(url, square: points, resize: resize)
    }

    /// Rectangular render target — use for banner / card backgrounds
    /// where the displayed aspect ratio differs from the source.
    static func resized(_ urlString: String, width pw: CGFloat, height ph: CGFloat, resize: ResizeMode = .cover) -> URL? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let w = max(1, Int((pw * Self.scale).rounded()))
        let h = max(1, Int((ph * Self.scale).rounded()))
        return resized(url, width: w, height: h, resize: resize)
    }

    /// Display scale used to convert SwiftUI points into render
    /// pixels. Hard-coded to `3` rather than read from `UIScreen.main.scale`
    /// because:
    ///   1. iPhones the app actually ships on are all @2x or @3x; @3x
    ///      covers both with no visible quality loss.
    ///   2. Reading the live screen scale ties this helper to the main
    ///      actor, which would force every call site to be `@MainActor`
    ///      or hop the current actor — overkill for a URL builder.
    ///   3. A consistent scale keeps the cache keys stable: an iPhone
    ///      Pro and an iPhone SE viewing the same profile share the
    ///      same on-disk URLCache entries.
    private static let scale: CGFloat = 3

    enum ResizeMode: String, Sendable {
        case cover
        case contain
        case fill
    }
}
