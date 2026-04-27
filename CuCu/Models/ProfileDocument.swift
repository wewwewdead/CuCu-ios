import CoreGraphics
import Foundation

struct PageStyle: Codable, Hashable {
    var id: UUID
    var height: Double
    var backgroundHex: String
    var backgroundImagePath: String?
    var backgroundBlur: Double?
    var backgroundVignette: Double?
    /// Background pattern preset (paperGrid, dots, hearts, sparkles,
    /// checkers, sunset, meadow, hazyDusk). Decoded by
    /// `CanvasBackgroundPattern(key:)` at render time. Nil = no
    /// pattern. Optional so older drafts decode unchanged.
    var backgroundPatternKey: String?
    /// Opacity applied to the user-uploaded background image only.
    /// Range 0…1. Nil = fully opaque. Lets users dim a busy photo
    /// without changing the canvas color underneath. Optional so
    /// older drafts decode unchanged.
    var backgroundImageOpacity: Double?
    var rootChildrenIDs: [UUID]

    init(id: UUID = UUID(),
         height: Double = ProfileDocument.defaultPageHeight,
         backgroundHex: String = ProfileDocument.defaultPageBackgroundHex,
         backgroundImagePath: String? = nil,
         backgroundBlur: Double? = nil,
         backgroundVignette: Double? = nil,
         backgroundPatternKey: String? = nil,
         backgroundImageOpacity: Double? = nil,
         rootChildrenIDs: [UUID] = []) {
        self.id = id
        self.height = height
        self.backgroundHex = backgroundHex
        self.backgroundImagePath = backgroundImagePath
        self.backgroundBlur = backgroundBlur
        self.backgroundVignette = backgroundVignette
        self.backgroundPatternKey = backgroundPatternKey
        self.backgroundImageOpacity = backgroundImageOpacity
        self.rootChildrenIDs = rootChildrenIDs
    }
}

/// Root scene-graph document for one profile canvas.
///
/// The node store is a flat `[UUID: CanvasNode]` table. `rootChildrenIDs`
/// is retained as a transitional mirror of `pages[0].rootChildrenIDs`; new
/// code reads top-level nodes from each `PageStyle`. Each node's own
/// `childrenIDs` gives the order of its children. Parentage is derived
/// (see `parent(of:)`) rather than stored, so there is exactly one source of
/// truth for nested relationships.
///
/// `parentIndex` is a non-Codable cache of `child -> parent` derived from
/// the same source. It is rebuilt in `init(from:)` after decoding and
/// kept in sync inside every parenting mutation (`insert`, `remove`,
/// `duplicate` / `cloneSubtree`, `bringToFront`, `sendBackward`). It is
/// excluded from Equatable/Hashable because two content-equal documents
/// must hash and compare equal regardless of how their indexes were
/// built — and because the index is derived, equal sources always
/// produce equal indexes anyway.
struct ProfileDocument: Codable, Hashable {
    static let defaultPageWidth: Double = 390
    static let defaultPageHeight: Double = 1000
    static let defaultPageBackgroundHex = "#F8F6F2"

    var id: UUID
    var pageWidth: Double
    var pageHeight: Double
    var pageBackgroundHex: String
    /// Optional relative path (resolved via `LocalCanvasAssetStore`) of an
    /// image rendered behind every node as the page background. When set,
    /// the image overlays `pageBackgroundHex` (so the color shows through
    /// any transparent pixels). `nil` = color only. Backward compatible —
    /// old drafts without this field decode unchanged.
    var pageBackgroundImagePath: String?
    /// Gaussian blur radius in CoreImage units, applied to the page
    /// background image. `nil` (or 0) means no blur. Range we expose
    /// in the UI is 0…30. Backward compatible — old drafts without
    /// this field decode unchanged.
    var pageBackgroundBlur: Double?
    /// Vignette intensity (0…~1.5). Higher = darker corners.
    /// `nil` (or 0) means no vignette.
    var pageBackgroundVignette: Double?
    var rootChildrenIDs: [UUID]
    var pages: [PageStyle]
    var nodes: [UUID: CanvasNode]

    /// `child -> parent` index. Rebuilt on decode, kept in sync by every
    /// mutation helper below. Not Codable; never serialized to disk.
    private var parentIndex: [UUID: UUID]

    /// Monotonic counter bumped on mutations that don't otherwise
    /// change the structural document — e.g. replacing an image at a
    /// deterministic filename (the path string stays identical; only
    /// the bytes on disk differ). Excluded from `Codable` so it
    /// doesn't bloat saved drafts; **included in Equatable / Hashable**
    /// so SwiftUI's `@State` diffing sees these no-structural-change
    /// mutations as updates and re-emits `updateUIView`. Without it,
    /// `lhs == rhs` returns true after a same-path replace, the host
    /// body skips re-evaluation, and the canvas never rebinds the
    /// new bytes (which the cache + renderSignature layers would
    /// otherwise surface fine). Inverse complement of `parentIndex`,
    /// which is *in* Codable but *excluded* from Equatable.
    var renderRevision: UInt64 = 0

    init(id: UUID = UUID(),
         pageWidth: Double = ProfileDocument.defaultPageWidth,
         pageHeight: Double = ProfileDocument.defaultPageHeight,
         pageBackgroundHex: String = ProfileDocument.defaultPageBackgroundHex,
         pageBackgroundImagePath: String? = nil,
         pageBackgroundBlur: Double? = nil,
         pageBackgroundVignette: Double? = nil,
         rootChildrenIDs: [UUID] = [],
         pages: [PageStyle]? = nil,
         nodes: [UUID: CanvasNode] = [:]) {
        self.id = id
        self.pageWidth = pageWidth
        if let pages, let first = pages.first {
            self.pages = pages
            self.pageHeight = first.height
            self.pageBackgroundHex = first.backgroundHex
            self.pageBackgroundImagePath = first.backgroundImagePath
            self.pageBackgroundBlur = first.backgroundBlur
            self.pageBackgroundVignette = first.backgroundVignette
            self.rootChildrenIDs = first.rootChildrenIDs
        } else {
            self.pageHeight = pageHeight
            self.pageBackgroundHex = pageBackgroundHex
            self.pageBackgroundImagePath = pageBackgroundImagePath
            self.pageBackgroundBlur = pageBackgroundBlur
            self.pageBackgroundVignette = pageBackgroundVignette
            self.rootChildrenIDs = rootChildrenIDs
            self.pages = [
                PageStyle(
                    height: pageHeight,
                    backgroundHex: pageBackgroundHex,
                    backgroundImagePath: pageBackgroundImagePath,
                    backgroundBlur: pageBackgroundBlur,
                    backgroundVignette: pageBackgroundVignette,
                    rootChildrenIDs: rootChildrenIDs
                )
            ]
        }
        self.nodes = nodes
        self.parentIndex = Self.buildParentIndex(nodes: nodes)
    }

    static var blank: ProfileDocument { ProfileDocument() }
}

extension ProfileDocument {
    private enum CodingKeys: String, CodingKey {
        case id
        case pageWidth
        case pageHeight
        case pageBackgroundHex
        case pageBackgroundImagePath
        case pageBackgroundBlur
        case pageBackgroundVignette
        case rootChildrenIDs
        case pages
        case nodes
        // `parentIndex` is intentionally absent — derived state, never persisted.
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.pageWidth = try c.decodeIfPresent(Double.self, forKey: .pageWidth) ?? Self.defaultPageWidth
        let legacyPageHeight = try c.decodeIfPresent(Double.self, forKey: .pageHeight) ?? Self.defaultPageHeight
        let legacyBackgroundHex = try c.decodeIfPresent(String.self, forKey: .pageBackgroundHex) ?? Self.defaultPageBackgroundHex
        let legacyBackgroundImagePath = try c.decodeIfPresent(String.self, forKey: .pageBackgroundImagePath)
        let legacyBackgroundBlur = try c.decodeIfPresent(Double.self, forKey: .pageBackgroundBlur)
        let legacyBackgroundVignette = try c.decodeIfPresent(Double.self, forKey: .pageBackgroundVignette)
        let legacyRootChildrenIDs = try c.decodeIfPresent([UUID].self, forKey: .rootChildrenIDs) ?? []
        if let decodedPages = try c.decodeIfPresent([PageStyle].self, forKey: .pages),
           let first = decodedPages.first {
            self.pages = decodedPages
            self.pageHeight = first.height
            self.pageBackgroundHex = first.backgroundHex
            self.pageBackgroundImagePath = first.backgroundImagePath
            self.pageBackgroundBlur = first.backgroundBlur
            self.pageBackgroundVignette = first.backgroundVignette
            self.rootChildrenIDs = first.rootChildrenIDs
        } else {
            self.pageHeight = legacyPageHeight
            self.pageBackgroundHex = legacyBackgroundHex
            self.pageBackgroundImagePath = legacyBackgroundImagePath
            self.pageBackgroundBlur = legacyBackgroundBlur
            self.pageBackgroundVignette = legacyBackgroundVignette
            self.rootChildrenIDs = legacyRootChildrenIDs
            self.pages = [
                PageStyle(
                    height: legacyPageHeight,
                    backgroundHex: legacyBackgroundHex,
                    backgroundImagePath: legacyBackgroundImagePath,
                    backgroundBlur: legacyBackgroundBlur,
                    backgroundVignette: legacyBackgroundVignette,
                    rootChildrenIDs: legacyRootChildrenIDs
                )
            ]
        }
        self.nodes = try c.decodeIfPresent([UUID: CanvasNode].self, forKey: .nodes) ?? [:]
        self.parentIndex = Self.buildParentIndex(nodes: self.nodes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let mirroredFirstPage = pages.first ?? PageStyle(
            height: pageHeight,
            backgroundHex: pageBackgroundHex,
            backgroundImagePath: pageBackgroundImagePath,
            backgroundBlur: pageBackgroundBlur,
            backgroundVignette: pageBackgroundVignette,
            rootChildrenIDs: rootChildrenIDs
        )

        try c.encode(id, forKey: .id)
        try c.encode(pageWidth, forKey: .pageWidth)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(pages.isEmpty ? [mirroredFirstPage] : pages, forKey: .pages)

        // Transitional dual-emit: old clients still read these top-level
        // fields, so keep them mirrored from page 1 until every viewer reads
        // `pages`.
        try c.encode(mirroredFirstPage.height, forKey: .pageHeight)
        try c.encode(mirroredFirstPage.backgroundHex, forKey: .pageBackgroundHex)
        try c.encodeIfPresent(mirroredFirstPage.backgroundImagePath, forKey: .pageBackgroundImagePath)
        try c.encodeIfPresent(mirroredFirstPage.backgroundBlur, forKey: .pageBackgroundBlur)
        try c.encodeIfPresent(mirroredFirstPage.backgroundVignette, forKey: .pageBackgroundVignette)
        try c.encode(mirroredFirstPage.rootChildrenIDs, forKey: .rootChildrenIDs)
    }

    static func == (lhs: ProfileDocument, rhs: ProfileDocument) -> Bool {
        lhs.id == rhs.id &&
        lhs.pageWidth == rhs.pageWidth &&
        lhs.pageHeight == rhs.pageHeight &&
        lhs.pageBackgroundHex == rhs.pageBackgroundHex &&
        lhs.pageBackgroundImagePath == rhs.pageBackgroundImagePath &&
        lhs.pageBackgroundBlur == rhs.pageBackgroundBlur &&
        lhs.pageBackgroundVignette == rhs.pageBackgroundVignette &&
        lhs.rootChildrenIDs == rhs.rootChildrenIDs &&
        lhs.pages == rhs.pages &&
        lhs.nodes == rhs.nodes &&
        lhs.renderRevision == rhs.renderRevision
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pageWidth)
        hasher.combine(pageHeight)
        hasher.combine(pageBackgroundHex)
        hasher.combine(pageBackgroundImagePath)
        hasher.combine(pageBackgroundBlur)
        hasher.combine(pageBackgroundVignette)
        hasher.combine(rootChildrenIDs)
        hasher.combine(pages)
        hasher.combine(nodes)
        hasher.combine(renderRevision)
    }

    private static func buildParentIndex(nodes: [UUID: CanvasNode]) -> [UUID: UUID] {
        var index: [UUID: UUID] = [:]
        index.reserveCapacity(nodes.count)
        for (parentID, node) in nodes {
            for childID in node.childrenIDs {
                index[childID] = parentID
            }
        }
        return index
    }
}

// MARK: - Tree queries

extension ProfileDocument {
    mutating func syncLegacyFieldsFromFirstPage() {
        guard let first = pages.first else { return }
        pageHeight = first.height
        pageBackgroundHex = first.backgroundHex
        pageBackgroundImagePath = first.backgroundImagePath
        pageBackgroundBlur = first.backgroundBlur
        pageBackgroundVignette = first.backgroundVignette
        rootChildrenIDs = first.rootChildrenIDs
    }

    /// Return the parent ID of `id`, or nil if it is a root child or unknown.
    /// O(1) dictionary lookup against `parentIndex`. Falls back to a linear
    /// scan only when the index is missing an entry — that path is an
    /// invariant violation in any post-mutation state, so we assert in
    /// debug to surface the drift while still self-healing in release.
    func parent(of id: UUID) -> UUID? {
        if pages.contains(where: { $0.rootChildrenIDs.contains(id) }) { return nil }
        if let parentID = parentIndex[id] { return parentID }
        // Index miss. Either the node is unknown (legitimate `nil`) or
        // the index drifted from `nodes` (a bug). Fall back to a scan.
        for (parentID, node) in nodes where node.childrenIDs.contains(id) {
            assertionFailure("ProfileDocument.parentIndex missing entry for \(id); self-healing via scan")
            return parentID
        }
        return nil
    }

    /// True if `id` is the page root (i.e., not in `nodes` but IDs in
    /// `rootChildrenIDs` belong to it).
    func isRoot(_ id: UUID?) -> Bool { id == nil }

    /// Return the page index whose root tree contains `nodeID`.
    func pageContaining(_ nodeID: UUID) -> Int? {
        guard nodes[nodeID] != nil else { return nil }
        var rootID = nodeID
        var current = parent(of: nodeID)
        while let parentID = current {
            rootID = parentID
            current = parent(of: parentID)
        }
        return pages.firstIndex { $0.rootChildrenIDs.contains(rootID) }
    }

    /// All descendant node IDs of `rootID`, depth-first, including `rootID`.
    func subtree(rootedAt rootID: UUID) -> [UUID] {
        var result: [UUID] = []
        var stack: [UUID] = [rootID]
        while let next = stack.popLast() {
            result.append(next)
            if let n = nodes[next] {
                stack.append(contentsOf: n.childrenIDs)
            }
        }
        return result
    }

    /// Ordered children IDs for any parent. Pass `nil` for the page root.
    func children(of parentID: UUID?, onPage pageIndex: Int) -> [UUID] {
        if let parentID, let node = nodes[parentID] { return node.childrenIDs }
        guard pages.indices.contains(pageIndex) else { return [] }
        return pages[pageIndex].rootChildrenIDs
    }

    /// Back-compat root lookup. New callers that need a page root should use
    /// `children(of:onPage:)`; the nil-parent form resolves to the last page
    /// to keep older add/reorder call sites working during the migration.
    func children(of parentID: UUID?) -> [UUID] {
        children(of: parentID, onPage: max(0, pages.count - 1))
    }
}

// MARK: - Mutation helpers

extension ProfileDocument {
    mutating func appendPage(inheritingFrom sourceIndex: Int) {
        let source = pages.indices.contains(sourceIndex) ? pages[sourceIndex] : pages.last
        pages.append(PageStyle(
            height: Self.defaultPageHeight,
            backgroundHex: source?.backgroundHex ?? Self.defaultPageBackgroundHex,
            backgroundImagePath: source?.backgroundImagePath,
            backgroundBlur: source?.backgroundBlur,
            backgroundVignette: source?.backgroundVignette,
            rootChildrenIDs: []
        ))
        syncLegacyFieldsFromFirstPage()
    }

    mutating func removePage(at index: Int) {
        guard pages.indices.contains(index), pages.count > 1 else { return }
        let rootIDs = pages[index].rootChildrenIDs
        let toRemove = Set(rootIDs.flatMap { subtree(rootedAt: $0) })
        for id in toRemove {
            nodes.removeValue(forKey: id)
            parentIndex.removeValue(forKey: id)
        }
        for id in toRemove {
            parentIndex.removeValue(forKey: id)
        }
        pages.remove(at: index)
        syncLegacyFieldsFromFirstPage()
    }

    /// Insert a node as a child of `parentID` (nil = page root). Appends to the
    /// end of the children list, which corresponds to top-of-stack visually.
    mutating func insert(_ node: CanvasNode, under parentID: UUID?, onPage pageIndex: Int) {
        nodes[node.id] = node
        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.append(node.id)
            nodes[parentID] = parent
            parentIndex[node.id] = parentID
        } else {
            let targetIndex = pages.indices.contains(pageIndex) ? pageIndex : max(0, pages.count - 1)
            if pages.isEmpty {
                pages.append(PageStyle(rootChildrenIDs: [node.id]))
            } else {
                pages[targetIndex].rootChildrenIDs.append(node.id)
            }
            // Root children have no parent entry in the index.
            parentIndex.removeValue(forKey: node.id)
            syncLegacyFieldsFromFirstPage()
        }
    }

    /// Back-compat insertion. Nil parent means "last page" so existing add
    /// flows naturally place new root nodes on the newest page unless the host
    /// passes `insert(_:under:onPage:)` explicitly.
    mutating func insert(_ node: CanvasNode, under parentID: UUID?) {
        let pageIndex = parentID.flatMap { pageContaining($0) } ?? max(0, pages.count - 1)
        insert(node, under: parentID, onPage: pageIndex)
    }

    /// Remove a node and all its descendants. Cleans up the parent's children
    /// list as well so no dangling IDs remain.
    mutating func remove(_ id: UUID) {
        let parentID = parent(of: id)
        let pageIndex = pageContaining(id)
        let toRemove = subtree(rootedAt: id)
        for nid in toRemove {
            nodes.removeValue(forKey: nid)
            parentIndex.removeValue(forKey: nid)
        }

        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.removeAll { $0 == id }
            nodes[parentID] = parent
        } else {
            let targetIndex = pageIndex ?? pages.firstIndex { $0.rootChildrenIDs.contains(id) }
            if let targetIndex {
                pages[targetIndex].rootChildrenIDs.removeAll { $0 == id }
                syncLegacyFieldsFromFirstPage()
            }
        }
    }

    /// Deep-copy a subtree under the same parent with fresh UUIDs and a small
    /// visual offset. Returns the new root ID, or nil if `sourceID` is unknown.
    @discardableResult
    mutating func duplicate(_ sourceID: UUID, offset: CGSize = CGSize(width: 12, height: 12)) -> UUID? {
        guard nodes[sourceID] != nil else { return nil }
        let parentID = parent(of: sourceID)
        let pageIndex = pageContaining(sourceID)
        let newRoot = cloneSubtree(sourceID, offset: offset)
        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.append(newRoot)
            nodes[parentID] = parent
            parentIndex[newRoot] = parentID
        } else {
            if let pageIndex {
                pages[pageIndex].rootChildrenIDs.append(newRoot)
                syncLegacyFieldsFromFirstPage()
            }
        }
        return newRoot
    }

    /// Recursively copies a subtree, regenerating IDs and remapping children.
    /// The root copy gets `offset` applied; descendants keep their original
    /// frames (relative to their parent, so the visual layout is preserved).
    /// Each cloned descendant is registered in `parentIndex` against its
    /// new (cloned) parent. The root copy's parent link is set by the
    /// caller (`duplicate`) since this function doesn't know the target
    /// parent.
    private mutating func cloneSubtree(_ sourceID: UUID, offset: CGSize) -> UUID {
        guard let source = nodes[sourceID] else { return UUID() }
        var copy = source
        copy.id = UUID()
        copy.frame.x += Double(offset.width)
        copy.frame.y += Double(offset.height)
        copy.childrenIDs = source.childrenIDs.map { childID in
            cloneSubtree(childID, offset: .zero)
        }
        nodes[copy.id] = copy
        for childID in copy.childrenIDs {
            parentIndex[childID] = copy.id
        }
        return copy.id
    }

    mutating func bringToFront(_ id: UUID) {
        let parentID = parent(of: id)
        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.removeAll { $0 == id }
            parent.childrenIDs.append(id)
            nodes[parentID] = parent
        } else {
            if let pageIndex = pageContaining(id) {
                pages[pageIndex].rootChildrenIDs.removeAll { $0 == id }
                pages[pageIndex].rootChildrenIDs.append(id)
                syncLegacyFieldsFromFirstPage()
            }
        }
        // Reordering within a parent doesn't change parentage.
    }

    mutating func sendBackward(_ id: UUID) {
        let parentID = parent(of: id)
        if let parentID, var parent = nodes[parentID] {
            if let idx = parent.childrenIDs.firstIndex(of: id), idx > 0 {
                parent.childrenIDs.swapAt(idx, idx - 1)
                nodes[parentID] = parent
            }
        } else if let pageIndex = pageContaining(id),
                  let idx = pages[pageIndex].rootChildrenIDs.firstIndex(of: id),
                  idx > 0 {
            pages[pageIndex].rootChildrenIDs.swapAt(idx, idx - 1)
            syncLegacyFieldsFromFirstPage()
        }
        // Reordering within a parent doesn't change parentage.
    }
}
