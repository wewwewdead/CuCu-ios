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
///   1. `document.pages[*].backgroundImagePath`
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

        // 1. Page backgrounds. Mirror page 1 back into the legacy top-level
        // fields because ProfileDocument currently dual-emits both shapes.
        for index in copy.pages.indices {
            if let local = copy.pages[index].backgroundImagePath,
               let remote = pathMap[local] {
                copy.pages[index].backgroundImagePath = remote
            }
        }
        copy.syncLegacyFieldsFromFirstPage()

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
    /// or `https://`) or that reference a bundled asset (`bundled:…`,
    /// shipped as part of seeded default templates) are skipped — both
    /// resolve at render time without going through the upload step.
    static func localAssetPaths(in document: ProfileDocument) -> [String] {
        var paths = Set<String>()

        for page in document.pages {
            if let p = page.backgroundImagePath, isUploadable(p) {
                paths.insert(p)
            }
        }
        if let p = document.pageBackgroundImagePath, isUploadable(p) {
            paths.insert(p)
        }

        for node in document.nodes.values {
            if let p = node.style.backgroundImagePath, isUploadable(p) {
                paths.insert(p)
            }
            if let p = node.content.localImagePath, isUploadable(p) {
                paths.insert(p)
            }
            if let arr = node.content.imagePaths {
                for p in arr where isUploadable(p) {
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

    /// True when `value` is a non-empty path that points at the per-draft
    /// local asset store (the only kind we want to upload at publish time).
    /// Filters out empty strings, already-remote URLs, and `bundled:`
    /// references that resolve to the app's asset catalog.
    ///
    /// Internal-visible so `PublishService.collectUploads` can use the
    /// same filter when walking asset surfaces — both the path-list
    /// collector and the upload-queue collector need to skip bundled
    /// references, otherwise seeded default templates fail to publish
    /// with a missingAsset error on the placeholder tone images.
    static func isUploadable(_ value: String) -> Bool {
        !value.isEmpty && !isRemote(value) && !value.hasPrefix("bundled:")
    }
}
