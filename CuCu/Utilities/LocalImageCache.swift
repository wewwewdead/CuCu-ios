import UIKit

/// Shared, bounded cache for decoded local canvas images.
///
/// The source of truth remains the normalized JPEG on disk. Cache keys include
/// the relative path plus file modification date so deterministic same-path
/// replacements show the new bytes while repeated renders avoid disk decode.
final class LocalImageCache: NSObject {
    static let shared = LocalImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var keysByPath: [String: Set<String>] = [:]

    private override init() {
        cache.countLimit = 160
        cache.totalCostLimit = 80 * 1024 * 1024
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clear),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func image(for relativePath: String, fileURL: URL, modificationDate: Date?) -> UIImage? {
        let key = cacheKey(relativePath: relativePath, modificationDate: modificationDate)
        if let image = cache.object(forKey: key as NSString) {
            return image
        }

        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            return nil
        }

        cache.setObject(image, forKey: key as NSString, cost: estimatedCost(of: image))
        lock.lock()
        keysByPath[relativePath, default: []].insert(key)
        lock.unlock()
        return image
    }

    func remove(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        lock.lock()
        let keys = keysByPath.removeValue(forKey: relativePath) ?? []
        lock.unlock()
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func removeAll(under relativePrefix: String) {
        lock.lock()
        let matchingPaths = keysByPath.keys.filter { $0.hasPrefix(relativePrefix) }
        var keys: Set<String> = []
        for path in matchingPaths {
            keys.formUnion(keysByPath.removeValue(forKey: path) ?? [])
        }
        lock.unlock()
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    @objc func clear() {
        cache.removeAllObjects()
        lock.lock()
        keysByPath.removeAll()
        lock.unlock()
    }

    private func cacheKey(relativePath: String, modificationDate: Date?) -> String {
        let stamp = modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(relativePath)|\(stamp)"
    }

    private func estimatedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let scale = max(image.scale, 1)
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }
}
