import UIKit

/// Single dispatcher for "give me an image given an image-path string."
/// The string can be either a local relative path (from
/// `LocalCanvasAssetStore`) or an absolute remote URL (`https://…`,
/// after publish). Renderers shouldn't have to care which one they got;
/// they just call `loadSync` for fast paths and `loadAsync` for the rest.
///
/// Decision rule: `http://` or `https://` prefix → remote; anything else
/// is treated as a relative local path. This matches what the publish
/// flow rewrites paths to (Supabase public URLs always begin with
/// `https://`) and what the local asset store stores (relative paths
/// like `draft_<UUID>/image_<UUID>.jpg`).
enum CanvasImageLoader {

    /// True when `value` looks like an absolute URL we should fetch
    /// over the network instead of resolving against the local asset
    /// store.
    static func isRemote(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    /// Try to return an image immediately. For local paths this opens
    /// the file synchronously; for remote URLs it returns the cached
    /// bitmap if one exists, nil otherwise. Renderers use this as the
    /// first-paint try and fall back to `loadAsync` when nil.
    static func loadSync(_ pathOrURL: String?) -> UIImage? {
        guard let s = pathOrURL, !s.isEmpty else { return nil }
        if isRemote(s) {
            guard let url = URL(string: s) else { return nil }
            return RemoteImageCache.shared.cached(for: url)
        }
        return LocalCanvasAssetStore.loadUIImage(s)
    }

    /// Fetch the image, calling `completion` on the main queue when
    /// bytes are available (or nil on failure). For local paths this
    /// returns the file contents on the next main-queue tick — the
    /// async hop matches the remote path so callers don't need to
    /// special-case ordering.
    static func loadAsync(_ pathOrURL: String,
                          completion: @escaping (UIImage?) -> Void) {
        guard !pathOrURL.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if isRemote(pathOrURL) {
            guard let url = URL(string: pathOrURL) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            RemoteImageCache.shared.load(url: url, completion: completion)
        } else {
            // Local path — read on a background queue so we don't block
            // the main thread on disk I/O.
            DispatchQueue.global(qos: .userInitiated).async {
                let img = LocalCanvasAssetStore.loadUIImage(pathOrURL)
                DispatchQueue.main.async { completion(img) }
            }
        }
    }
}
