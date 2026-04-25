import CoreGraphics
import Foundation

/// Root scene-graph document for one profile page.
///
/// The node store is a flat `[UUID: CanvasNode]` table. `rootChildrenIDs`
/// gives the order/z-stack of top-level nodes; each node's own `childrenIDs`
/// gives the order of its children. Parentage is derived (see `parent(of:)`)
/// rather than stored, so there is exactly one source of truth.
struct ProfileDocument: Codable, Hashable {
    var id: UUID
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

    init(id: UUID = UUID(),
         pageBackgroundHex: String = "#F8F6F2",
         pageBackgroundImagePath: String? = nil,
         pageBackgroundBlur: Double? = nil,
         pageBackgroundVignette: Double? = nil,
         rootChildrenIDs: [UUID] = [],
         nodes: [UUID: CanvasNode] = [:]) {
        self.id = id
        self.pageBackgroundHex = pageBackgroundHex
        self.pageBackgroundImagePath = pageBackgroundImagePath
        self.pageBackgroundBlur = pageBackgroundBlur
        self.pageBackgroundVignette = pageBackgroundVignette
        self.rootChildrenIDs = rootChildrenIDs
        self.nodes = nodes
    }

    static var blank: ProfileDocument { ProfileDocument() }
}

// MARK: - Tree queries

extension ProfileDocument {
    /// Return the parent ID of `id`, or nil if it is a root child or unknown.
    /// Linear scan; only called from inspector/add/delete paths where N is
    /// small and the simplicity is worth the cost.
    func parent(of id: UUID) -> UUID? {
        if rootChildrenIDs.contains(id) { return nil }
        for (parentID, node) in nodes where node.childrenIDs.contains(id) {
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
        } else {
            rootChildrenIDs.append(node.id)
        }
    }

    /// Remove a node and all its descendants. Cleans up the parent's children
    /// list as well so no dangling IDs remain.
    mutating func remove(_ id: UUID) {
        let parentID = parent(of: id)
        let toRemove = subtree(rootedAt: id)
        for nid in toRemove { nodes.removeValue(forKey: nid) }

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
        } else {
            rootChildrenIDs.append(newRoot)
        }
        return newRoot
    }

    /// Recursively copies a subtree, regenerating IDs and remapping children.
    /// The root copy gets `offset` applied; descendants keep their original
    /// frames (relative to their parent, so the visual layout is preserved).
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
    }
}
