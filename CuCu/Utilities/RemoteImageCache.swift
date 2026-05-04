import ImageIO
import UIKit

/// In-memory cache for images fetched from `https://` URLs (Supabase Storage
/// public URLs in this app). Backed by `NSCache` so the OS can evict under
/// memory pressure; persistent caching is delegated to URLSession's own disk
/// cache via `URLSessionConfiguration.default`.
///
/// The cache is intentionally minimal — no progress reporting, no
/// thumbnail/fullsize tiering, no priority. Profile-viewer screens have
/// at most a few dozen images and the renderer just needs a fast
/// "give me bytes" + "tell me when bytes arrive" pair.
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 128
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// Coalesce concurrent requests for the same URL: if two views ask
    /// for the same image at the same time, only one network task runs
    /// and both completion handlers fire when bytes arrive. Keyed by
    /// the absolute URL string so equality matches the cache key.
    private var inflight: [String: [(@Sendable (UIImage?) -> Void)]] = [:]
    private let inflightQueue = DispatchQueue(label: "RemoteImageCache.inflight")

    private init() {}

    /// Synchronous cache lookup — returns the bitmap if it's resident,
    /// nil otherwise. The renderer uses this for the first-paint try
    /// before falling back to the async path.
    func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Fetch (or pull from cache) the image at `url`. Completion fires on
    /// the main queue with either the image or `nil` (network error,
    /// missing bytes, or non-image data). Calls into the same URL while
    /// a fetch is in flight are coalesced — only one network task runs
    /// per URL at a time.
    func load(url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        var shouldStart = false
        inflightQueue.sync {
            if var existing = inflight[key] {
                existing.append({ image in completion(image) })
                inflight[key] = existing
            } else {
                inflight[key] = [{ image in completion(image) }]
                shouldStart = true
            }
        }
        guard shouldStart else { return }

        session.dataTask(with: url) { [weak self] data, _, _ in
            let img = data.flatMap(Self.decodeRemoteImage)
            if let img, let self {
                self.cache.setObject(img, forKey: key as NSString, cost: self.estimatedCost(of: img))
            }
            // Pull and clear all waiters under the lock, then invoke
            // them on the main queue.
            var waiters: [(@Sendable (UIImage?) -> Void)] = []
            self?.inflightQueue.sync {
                waiters = self?.inflight[key] ?? []
                self?.inflight[key] = nil
            }
            DispatchQueue.main.async {
                for w in waiters { w(img) }
            }
        }.resume()
    }

    /// Drop everything from the in-memory cache. Called rarely — useful
    /// for QA tooling to confirm fresh fetches.
    func clearMemoryCache() {
        cache.removeAllObjects()
    }

    private func estimatedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let scale = max(image.scale, 1)
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    nonisolated private static func decodeRemoteImage(data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }

        // Preserve animated images through UIKit's existing decoder. Canvas
        // assets are normally static, but this avoids silently flattening GIFs.
        guard CGImageSourceGetCount(source) <= 1 else {
            return UIImage(data: data)
        }

        let maxPixelSize = 2_400
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else {
            return UIImage(data: data)
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumbnail)
    }
}
