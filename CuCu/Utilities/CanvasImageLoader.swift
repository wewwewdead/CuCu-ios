import UIKit

/// Single dispatcher for "give me an image given an image-path string."
/// The string can be either a local relative path (from
/// `LocalCanvasAssetStore`), an absolute remote URL (`https://…`, after
/// publish), or a bundled asset reference (`bundled:<name>`, used by
/// seeded default templates that ship images inside Assets.xcassets).
/// Renderers shouldn't have to care which one they got; they just call
/// `loadSync` for fast paths and `loadAsync` for the rest.
///
/// Decision rule: `http(s)://` → remote; `bundled:` → asset catalog;
/// anything else → relative local path under `LocalCanvasAssetStore`.
enum CanvasImageLoader {

    /// True when `value` looks like an absolute URL we should fetch
    /// over the network instead of resolving against the local asset
    /// store.
    static func isRemote(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    /// True when `value` references an image bundled inside the app's
    /// asset catalog (e.g. `"bundled:tone-peach"`). Used by seeded
    /// default templates so the picker can ship pre-styled placeholder
    /// images without needing to copy bytes into a per-draft folder.
    /// The publish pipeline skips these — bundled placeholders are
    /// expected to be replaced by the user before publishing.
    static func isBundled(_ value: String) -> Bool {
        value.hasPrefix("bundled:")
    }

    /// Strip the `bundled:` prefix and return the asset-catalog name.
    static func bundledName(_ value: String) -> String? {
        guard isBundled(value) else { return nil }
        return String(value.dropFirst("bundled:".count))
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
        if let name = bundledName(s) {
            return UIImage(named: name)
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
        } else if let name = bundledName(pathOrURL) {
            // Bundled asset catalog lookup — UIImage(named:) is fast and
            // already cached, but we still hop to main on the next tick
            // so callers can rely on a consistent async contract.
            DispatchQueue.main.async {
                completion(UIImage(named: name))
            }
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
