import CoreGraphics
import Foundation

/// Root scene-graph document for one profile page.
///
/// The node store is a flat `[UUID: CanvasNode]` table. `rootChildrenIDs`
/// gives the order/z-stack of top-level nodes; each node's own `childrenIDs`
/// gives the order of its children. Parentage is derived (see `parent(of:)`)
/// rather than stored, so there is exactly one source of truth.
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
    var nodes: [UUID: CanvasNode]

    /// `child -> parent` index. Rebuilt on decode, kept in sync by every
    /// mutation helper below. Not Codable; never serialized to disk.
    private var parentIndex: [UUID: UUID]

    init(id: UUID = UUID(),
         pageWidth: Double = ProfileDocument.defaultPageWidth,
         pageHeight: Double = ProfileDocument.defaultPageHeight,
         pageBackgroundHex: String = ProfileDocument.defaultPageBackgroundHex,
         pageBackgroundImagePath: String? = nil,
         pageBackgroundBlur: Double? = nil,
         pageBackgroundVignette: Double? = nil,
         rootChildrenIDs: [UUID] = [],
         nodes: [UUID: CanvasNode] = [:]) {
        self.id = id
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.pageBackgroundHex = pageBackgroundHex
        self.pageBackgroundImagePath = pageBackgroundImagePath
        self.pageBackgroundBlur = pageBackgroundBlur
        self.pageBackgroundVignette = pageBackgroundVignette
        self.rootChildrenIDs = rootChildrenIDs
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
        case nodes
        // `parentIndex` is intentionally absent — derived state, never persisted.
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.pageWidth = try c.decodeIfPresent(Double.self, forKey: .pageWidth) ?? Self.defaultPageWidth
        self.pageHeight = try c.decodeIfPresent(Double.self, forKey: .pageHeight) ?? Self.defaultPageHeight
        self.pageBackgroundHex = try c.decodeIfPresent(String.self, forKey: .pageBackgroundHex) ?? Self.defaultPageBackgroundHex
        self.pageBackgroundImagePath = try c.decodeIfPresent(String.self, forKey: .pageBackgroundImagePath)
        self.pageBackgroundBlur = try c.decodeIfPresent(Double.self, forKey: .pageBackgroundBlur)
        self.pageBackgroundVignette = try c.decodeIfPresent(Double.self, forKey: .pageBackgroundVignette)
        self.rootChildrenIDs = try c.decodeIfPresent([UUID].self, forKey: .rootChildrenIDs) ?? []
        self.nodes = try c.decodeIfPresent([UUID: CanvasNode].self, forKey: .nodes) ?? [:]
        self.parentIndex = Self.buildParentIndex(nodes: self.nodes)
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
        lhs.nodes == rhs.nodes
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
        hasher.combine(nodes)
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
    /// Return the parent ID of `id`, or nil if it is a root child or unknown.
    /// O(1) dictionary lookup against `parentIndex`. Falls back to a linear
    /// scan only when the index is missing an entry — that path is an
    /// invariant violation in any post-mutation state, so we assert in
    /// debug to surface the drift while still self-healing in release.
    func parent(of id: UUID) -> UUID? {
        if rootChildrenIDs.contains(id) { return nil }
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
    func children(of parentID: UUID?) -> [UUID] {
        if let parentID, let node = nodes[parentID] { return node.childrenIDs }
        return rootChildrenIDs
    }
}

// MARK: - Mutation helpers

extension ProfileDocument {
    /// Insert a node as a child of `parentID` (nil = page root). Appends to the
    /// end of the children list, which corresponds to top-of-stack visually.
    mutating func insert(_ node: CanvasNode, under parentID: UUID?) {
        nodes[node.id] = node
        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.append(node.id)
            nodes[parentID] = parent
            parentIndex[node.id] = parentID
        } else {
            rootChildrenIDs.append(node.id)
            // Root children have no parent entry in the index.
            parentIndex.removeValue(forKey: node.id)
        }
    }

    /// Remove a node and all its descendants. Cleans up the parent's children
    /// list as well so no dangling IDs remain.
    mutating func remove(_ id: UUID) {
        let parentID = parent(of: id)
        let toRemove = subtree(rootedAt: id)
        for nid in toRemove {
            nodes.removeValue(forKey: nid)
            parentIndex.removeValue(forKey: nid)
        }

        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.removeAll { $0 == id }
            nodes[parentID] = parent
        } else {
            rootChildrenIDs.removeAll { $0 == id }
        }
    }

    /// Deep-copy a subtree under the same parent with fresh UUIDs and a small
    /// visual offset. Returns the new root ID, or nil if `sourceID` is unknown.
    @discardableResult
    mutating func duplicate(_ sourceID: UUID, offset: CGSize = CGSize(width: 12, height: 12)) -> UUID? {
        guard nodes[sourceID] != nil else { return nil }
        let parentID = parent(of: sourceID)
        let newRoot = cloneSubtree(sourceID, offset: offset)
        if let parentID, var parent = nodes[parentID] {
            parent.childrenIDs.append(newRoot)
            nodes[parentID] = parent
            parentIndex[newRoot] = parentID
        } else {
            rootChildrenIDs.append(newRoot)
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
            rootChildrenIDs.removeAll { $0 == id }
            rootChildrenIDs.append(id)
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
        } else if let idx = rootChildrenIDs.firstIndex(of: id), idx > 0 {
            rootChildrenIDs.swapAt(idx, idx - 1)
        }
        // Reordering within a parent doesn't change parentage.
    }
}
