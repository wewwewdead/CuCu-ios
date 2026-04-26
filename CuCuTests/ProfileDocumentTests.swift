//
//  ProfileDocumentTests.swift
//  CuCuTests
//
//  Verifies the parent index introduced for O(1) `parent(of:)` lookups
//  preserves the previous public-API behavior of `parent`, `subtree`,
//  `duplicate`, and `remove`. These are black-box tests against the same
//  fixture documents the previous (linear-scan) implementation served.
//

import Testing
import CoreGraphics
import Foundation
@testable import CuCu

private func makeContainer(_ id: UUID = UUID()) -> CanvasNode {
    CanvasNode(
        id: id,
        type: .container,
        frame: NodeFrame(x: 0, y: 0, width: 100, height: 100)
    )
}

private func makeText(_ id: UUID = UUID()) -> CanvasNode {
    CanvasNode(
        id: id,
        type: .text,
        frame: NodeFrame(x: 0, y: 0, width: 100, height: 40),
        content: NodeContent(text: "hello")
    )
}

/// Builds a fixture document with the structure:
///
///   page
///   ├── A (container)
///   │   ├── B (container)
///   │   │   └── C (text)
///   │   └── D (text)
///   └── E (container)
///       └── F (text)
private func makeFixture() -> (doc: ProfileDocument, ids: [String: UUID]) {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID()
    var doc = ProfileDocument.blank
    doc.insert(makeContainer(a), under: nil)
    doc.insert(makeContainer(b), under: a)
    doc.insert(makeText(c),      under: b)
    doc.insert(makeText(d),      under: a)
    doc.insert(makeContainer(e), under: nil)
    doc.insert(makeText(f),      under: e)
    return (doc, ["A": a, "B": b, "C": c, "D": d, "E": e, "F": f])
}

struct ProfileDocumentParentIndexTests {

    @Test func parentOfRootChildIsNil() async throws {
        let (doc, ids) = makeFixture()
        #expect(doc.parent(of: ids["A"]!) == nil)
        #expect(doc.parent(of: ids["E"]!) == nil)
    }

    @Test func parentOfNestedChildMatchesContainer() async throws {
        let (doc, ids) = makeFixture()
        #expect(doc.parent(of: ids["B"]!) == ids["A"])
        #expect(doc.parent(of: ids["C"]!) == ids["B"])
        #expect(doc.parent(of: ids["D"]!) == ids["A"])
        #expect(doc.parent(of: ids["F"]!) == ids["E"])
    }

    @Test func parentOfUnknownIDIsNil() async throws {
        let (doc, _) = makeFixture()
        #expect(doc.parent(of: UUID()) == nil)
    }

    @Test func subtreeIncludesAllDescendantsAndRoot() async throws {
        let (doc, ids) = makeFixture()
        let subtreeA = Set(doc.subtree(rootedAt: ids["A"]!))
        #expect(subtreeA == Set([ids["A"]!, ids["B"]!, ids["C"]!, ids["D"]!]))

        let subtreeE = Set(doc.subtree(rootedAt: ids["E"]!))
        #expect(subtreeE == Set([ids["E"]!, ids["F"]!]))

        let subtreeC = Set(doc.subtree(rootedAt: ids["C"]!))
        #expect(subtreeC == Set([ids["C"]!]))
    }

    @Test func removeDropsSubtreeAndDetachesParent() async throws {
        var (doc, ids) = makeFixture()
        doc.remove(ids["B"]!)
        // B and C are gone.
        #expect(doc.nodes[ids["B"]!] == nil)
        #expect(doc.nodes[ids["C"]!] == nil)
        // A remains; D is still A's child; B is no longer in A's children.
        let aChildren = doc.nodes[ids["A"]!]?.childrenIDs ?? []
        #expect(aChildren == [ids["D"]!])
        // parent(of: B) and (of: C) are nil since they are unknown.
        #expect(doc.parent(of: ids["B"]!) == nil)
        #expect(doc.parent(of: ids["C"]!) == nil)
        // D's parent is still A.
        #expect(doc.parent(of: ids["D"]!) == ids["A"])
    }

    @Test func removeRootChildDropsFromRootChildrenList() async throws {
        var (doc, ids) = makeFixture()
        doc.remove(ids["E"]!)
        #expect(!doc.rootChildrenIDs.contains(ids["E"]!))
        #expect(doc.nodes[ids["E"]!] == nil)
        #expect(doc.nodes[ids["F"]!] == nil)
        // Other side untouched.
        #expect(doc.rootChildrenIDs.contains(ids["A"]!))
        #expect(doc.parent(of: ids["A"]!) == nil)
    }

    @Test func duplicateRootSubtreeAttachesUnderSameRoot() async throws {
        var (doc, ids) = makeFixture()
        let newRoot = doc.duplicate(ids["E"]!)
        #expect(newRoot != nil)
        #expect(newRoot != ids["E"])
        // New root is now a root child too.
        #expect(doc.rootChildrenIDs.contains(newRoot!))
        // Parent of the new root is nil (it's a root child).
        #expect(doc.parent(of: newRoot!) == nil)
        // The duplicated subtree contains exactly two nodes and both are new IDs.
        let subtree = doc.subtree(rootedAt: newRoot!)
        #expect(subtree.count == 2)
        let originalIDs: Set<UUID> = [ids["E"]!, ids["F"]!]
        for nid in subtree {
            #expect(!originalIDs.contains(nid))
        }
        // The cloned child's parent is the cloned root (index correctness).
        let clonedChildren = doc.nodes[newRoot!]?.childrenIDs ?? []
        #expect(clonedChildren.count == 1)
        #expect(doc.parent(of: clonedChildren[0]) == newRoot)
    }

    @Test func duplicateNestedSubtreeAttachesUnderSameParent() async throws {
        var (doc, ids) = makeFixture()
        let newRoot = doc.duplicate(ids["B"]!)
        #expect(newRoot != nil)
        // Cloned root attaches to A (B's parent).
        #expect(doc.parent(of: newRoot!) == ids["A"])
        // A's children now include both the original B and the cloned root.
        let aChildren = doc.nodes[ids["A"]!]?.childrenIDs ?? []
        #expect(aChildren.contains(ids["B"]!))
        #expect(aChildren.contains(newRoot!))
        // Cloned descendants are reachable and parented to their cloned ancestor.
        let cloned = doc.subtree(rootedAt: newRoot!)
        #expect(cloned.count == 2)
        let clonedChild = doc.nodes[newRoot!]?.childrenIDs.first
        #expect(clonedChild != nil)
        #expect(doc.parent(of: clonedChild!) == newRoot)
    }

    @Test func bringToFrontMovesIDToEndOfParentChildren() async throws {
        var (doc, ids) = makeFixture()
        // A's order is [B, D]. Bring B to front.
        doc.bringToFront(ids["B"]!)
        let aChildren = doc.nodes[ids["A"]!]?.childrenIDs ?? []
        #expect(aChildren == [ids["D"]!, ids["B"]!])
        // Parent unchanged.
        #expect(doc.parent(of: ids["B"]!) == ids["A"])
        #expect(doc.parent(of: ids["D"]!) == ids["A"])
    }

    @Test func sendBackwardSwapsWithPreviousSibling() async throws {
        var (doc, ids) = makeFixture()
        // A's order is [B, D]. Send D backward.
        doc.sendBackward(ids["D"]!)
        let aChildren = doc.nodes[ids["A"]!]?.childrenIDs ?? []
        #expect(aChildren == [ids["D"]!, ids["B"]!])
        // Parent unchanged.
        #expect(doc.parent(of: ids["D"]!) == ids["A"])
        #expect(doc.parent(of: ids["B"]!) == ids["A"])
    }

    @Test func encodeDecodeRoundtripPreservesParentLookup() async throws {
        let (doc, ids) = makeFixture()
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ProfileDocument.self, from: data)
        // Index is rebuilt on decode — every parent lookup must match.
        for (label, id) in ids {
            #expect(decoded.parent(of: id) == doc.parent(of: id),
                    "parent(of: \(label)) drifted across encode/decode")
        }
        // Subtree shapes match too.
        for id in ids.values {
            #expect(Set(decoded.subtree(rootedAt: id)) == Set(doc.subtree(rootedAt: id)))
        }
    }
}
