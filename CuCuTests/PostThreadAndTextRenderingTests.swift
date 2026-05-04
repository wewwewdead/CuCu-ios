import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import CuCu

private func makePost(id: String,
                      parentId: String? = nil,
                      depth: Int = 0,
                      likeCount: Int = 0,
                      replyCount: Int = 0) -> Post {
    Post(
        id: id,
        authorId: "author-\(id)",
        authorUsername: "user\(id)",
        parentId: parentId,
        rootId: parentId == nil ? id : "root",
        depth: depth,
        body: "post \(id)",
        likeCount: likeCount,
        replyCount: replyCount,
        createdAt: Date(timeIntervalSince1970: Double(depth)),
        editedAt: nil
    )
}

struct PostThreadAndTextRenderingTests {
    @Test func optimisticMutationTokensRejectStaleCompletions() async throws {
        var tokens = OptimisticMutationTokens()
        let first = tokens.begin(for: "post")
        let second = tokens.begin(for: "post")

        let firstFinished = tokens.finish(first, for: "post")
        #expect(!tokens.isCurrent(first, for: "post"))
        #expect(!firstFinished)
        #expect(tokens.isCurrent(second, for: "post"))
        let secondFinished = tokens.finish(second, for: "post")
        #expect(secondFinished)
    }

    @Test func optimisticMutationTokensInvalidateOnRefresh() async throws {
        var tokens = OptimisticMutationTokens()
        let stale = tokens.begin(for: "post")
        tokens.invalidateAll()

        let staleFinished = tokens.finish(stale, for: "post")
        #expect(!tokens.isCurrent(stale, for: "post"))
        #expect(!staleFinished)
    }

    @Test func threadRootRendersFromPostsDictionary() async throws {
        let root = makePost(id: "root", replyCount: 1)
        var thread = PostThread(
            rootId: root.id,
            posts: [root.id: root],
            childrenByParent: [root.id: []],
            expandedIds: [root.id],
            nextCursorByParent: [:],
            hasMoreByParent: [:],
            loadingByParent: []
        )

        var freshRoot = root
        freshRoot.likeCount = 3
        freshRoot.replyCount = 2
        thread.posts[root.id] = freshRoot

        guard case .post(let renderedRoot, _, _) = thread.flattenForRender().first else {
            Issue.record("Expected the first render item to be the root post")
            return
        }
        #expect(renderedRoot.likeCount == 3)
        #expect(renderedRoot.replyCount == 2)
    }

    @MainActor
    @Test func textNodeSkipsAttributedRebuildForFrameAndOpacityChanges() async throws {
        let id = UUID()
        var node = CanvasNode(
            id: id,
            type: .text,
            frame: NodeFrame(x: 0, y: 0, width: 180, height: 44),
            style: NodeStyle(
                fontFamily: .system,
                fontWeight: .regular,
                fontSize: 17,
                textColorHex: "#111111",
                textAlignment: .leading
            ),
            content: NodeContent(text: "hello")
        )
        let view = TextNodeView(nodeID: id)

        TextNodeView.resetAttributedTextRebuildCount()
        view.apply(node: node)
        #expect(TextNodeView.attributedTextRebuildCount == 1)

        node.frame = NodeFrame(x: 24, y: 16, width: 220, height: 44)
        view.apply(node: node)
        #expect(TextNodeView.attributedTextRebuildCount == 1)

        node.opacity = 0.5
        view.apply(node: node)
        #expect(TextNodeView.attributedTextRebuildCount == 1)

        node.style.textColorHex = "#222222"
        view.apply(node: node)
        #expect(TextNodeView.attributedTextRebuildCount == 2)
    }
}
