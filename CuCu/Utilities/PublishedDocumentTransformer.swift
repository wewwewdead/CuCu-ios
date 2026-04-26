import Foundation

/// Pure transformation that returns a copy of a `ProfileDocument` with every
/// local image path swapped for the corresponding public URL.
///
/// The transformer never reads disk and never throws. The publish service
/// builds a `pathMap` while uploading; the transformer applies that map.
/// If a path is missing from the map (e.g. the upload step decided not to
/// upload it), the original value is preserved unchanged — the renderer's
/// remote/local fork falls back to a placeholder for unresolved paths.
///
/// Surfaces transformed:
///   1. `document.pageBackgroundImagePath`
///   2. `node.style.backgroundImagePath`        (container backgrounds)
///   3. `node.content.localImagePath`           (image nodes)
///   4. `node.content.imagePaths`               (gallery nodes — array)
///
/// The local draft document is never mutated. Callers pass the local
/// `ProfileDocument` in and use the returned copy for the published
/// `design_json` payload only.
enum PublishedDocumentTransformer {
    /// Rewrites every local-relative path in `document` using `pathMap`
    /// (`localRelativePath → publicURL`). Paths not present in the map
    /// are left as-is.
    static func transform(_ document: ProfileDocument,
                          replacing pathMap: [String: String]) -> ProfileDocument {
        var copy = document

        // 1. Page background.
        if let local = copy.pageBackgroundImagePath, let remote = pathMap[local] {
            copy.pageBackgroundImagePath = remote
        }

        // 2-4. Walk every node — leaf types update content paths, containers
        // update style.backgroundImagePath. Galleries update an array of
        // paths individually.
        for (id, node) in document.nodes {
            var next = node

            if let local = node.style.backgroundImagePath,
               let remote = pathMap[local] {
                next.style.backgroundImagePath = remote
            }

            if let local = node.content.localImagePath,
               let remote = pathMap[local] {
                next.content.localImagePath = remote
            }

            if let paths = node.content.imagePaths, !paths.isEmpty {
                next.content.imagePaths = paths.map { local in
                    pathMap[local] ?? local
                }
            }

            copy.nodes[id] = next
        }

        return copy
    }

    /// Enumerate every local-relative path inside `document` that needs to
    /// be uploaded. De-duplicated; preserves no particular order. Empty
    /// strings are filtered. Strings that already look remote (`http://`
    /// or `https://`) are skipped — a re-publish where the local draft
    /// somehow already carries a remote URL won't re-upload it.
    static func localAssetPaths(in document: ProfileDocument) -> [String] {
        var paths = Set<String>()

        if let p = document.pageBackgroundImagePath, !isRemote(p) {
            paths.insert(p)
        }

        for node in document.nodes.values {
            if let p = node.style.backgroundImagePath, !p.isEmpty, !isRemote(p) {
                paths.insert(p)
            }
            if let p = node.content.localImagePath, !p.isEmpty, !isRemote(p) {
                paths.insert(p)
            }
            if let arr = node.content.imagePaths {
                for p in arr where !p.isEmpty && !isRemote(p) {
                    paths.insert(p)
                }
            }
        }

        return Array(paths)
    }

    /// Heuristic match for already-public URLs. Used both here and at
    /// render time so the canvas / viewer can decide local vs. remote.
    static func isRemote(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }
}
