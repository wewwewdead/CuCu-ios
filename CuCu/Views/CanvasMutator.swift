import Foundation
import SwiftData
import SwiftUI

/// All the document-mutation methods that previously lived as private
/// helpers on `ProfileCanvasBuilderView`, lifted into a single struct
/// so the view's `body` doesn't have to carry them.
///
/// The mutator is a value type that holds bindings into the view's
/// state; calling it from the view is identical in semantics to the
/// previous inline implementations. Each method preserves the same
/// persistence contract — every committed mutation calls
/// `store.updateDocument(...)` exactly once at the end, matching the
/// pre-extraction cadence.
@MainActor
struct CanvasMutator {
    let document: Binding<ProfileDocument>
    let selectedID: Binding<UUID?>
    let draft: ProfileDraft
    let store: DraftStore
    let context: ModelContext
    // MARK: - Add

    /// Insert a brand-new node of `type` under the currently-selected
    /// container, or under the page root. `image` and `gallery` go
    /// through the dedicated bytes-bearing helpers below — those cases
    /// are noops here on purpose so the switch stays exhaustive.
    func addNode(of type: NodeType) {
        let parentID = parentForInsertion()
        let node: CanvasNode
        switch type {
        case .container:
            node = isCarousel(parentID)
                ? carouselContainerItem(parentID: parentID)
                : .defaultContainer()
        case .text:
            node = isCarousel(parentID)
                ? carouselTextItem(parentID: parentID)
                : .defaultText()
        case .image:     return
        case .icon:
            node = isCarousel(parentID)
                ? carouselIconItem(parentID: parentID)
                : .defaultIcon()
        case .divider:
            node = isCarousel(parentID)
                ? CanvasNode.defaultDivider(at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 120, height: 28)),
                                            size: CGSize(width: 120, height: 28))
                : .defaultDivider()
        case .link:
            node = isCarousel(parentID)
                ? CanvasNode.defaultLink(at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 150, height: 48)),
                                         size: CGSize(width: 150, height: 48))
                : .defaultLink()
        case .gallery:   return
        case .carousel:
            let carousel = CanvasNode.defaultCarousel()
            document.wrappedValue.insert(carousel, under: parentID)
            selectedID.wrappedValue = carousel.id
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.soft()
            return
        }
        document.wrappedValue.insert(node, under: parentID)
        selectedID.wrappedValue = node.id
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.soft()
    }

    /// Save picked image bytes to disk and create an image node referencing
    /// that local path. If the save fails, no node is created — the user's
    /// canvas stays clean.
    @discardableResult
    func addImageNode(from data: Data) -> Bool {
        let parentID = parentForInsertion()
        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            var node = isCarousel(parentID)
                ? CanvasNode.defaultImage(
                    localImagePath: path,
                    at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 120, height: 96)),
                    size: CGSize(width: 120, height: 96)
                )
                : CanvasNode.defaultImage(localImagePath: path)
            node.id = nodeID
            document.wrappedValue.insert(node, under: parentID)
            selectedID.wrappedValue = nodeID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.soft()
            return true
        } catch {
            // Save failed — no broken node is added. The add sheet keeps
            // itself open and shows the user a retryable error.
            return false
        }
    }

    /// Save picked image bytes to disk and create an avatar node — a
    /// circle-clipped image at a square frame so the result is a true
    /// profile-pic circle on first paint. Identical disk-save path as
    /// `addImageNode`; only the style differs.
    @discardableResult
    func addAvatarNode(from data: Data) -> Bool {
        let parentID = parentForInsertion()
        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            // Square frame + circle clip = profile-pic circle. The
            // size is intentionally smaller than `defaultImage`'s
            // 200pt because avatars typically read better at ~120pt.
            let avatarSize = isCarousel(parentID)
                ? CGSize(width: 88, height: 88)
                : CGSize(width: 120, height: 120)
            var node = CanvasNode.defaultImage(
                localImagePath: path,
                at: isCarousel(parentID)
                    ? nextCarouselItemOrigin(parentID: parentID, size: avatarSize)
                    : CGPoint(x: 32, y: 80),
                size: avatarSize
            )
            node.id = nodeID
            node.style.clipShape = .circle
            // Subtle white ring so the avatar separates from any
            // page background — same convention `imagePlaceholderTree`
            // uses inside the hero preset.
            node.style.borderColorHex = "#FFFFFF"
            node.style.borderWidth = 2
            document.wrappedValue.insert(node, under: parentID)
            selectedID.wrappedValue = nodeID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.soft()
            return true
        } catch {
            return false
        }
    }

    /// Save each picked image's bytes to disk under fresh per-image
    /// UUIDs and create one gallery node referencing all of them. The
    /// gallery's own `id` is distinct from the image-asset UUIDs so the
    /// node and its assets don't collide. Skips bytes that fail to
    /// normalize — partial saves are better than zero-image galleries
    /// and the user can pick more from the inspector if they want.
    @discardableResult
    func addGalleryNode(from imageBytesList: [Data]) -> Bool {
        let parentID = parentForInsertion()

        var savedPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID
                )
                savedPaths.append(path)
            } catch {
                // Skip this image; keep the rest.
            }
        }
        guard !savedPaths.isEmpty else { return false }

        let node = isCarousel(parentID)
            ? CanvasNode.defaultGallery(
                imagePaths: savedPaths,
                at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 160, height: 104)),
                size: CGSize(width: 160, height: 104)
            )
            : CanvasNode.defaultGallery(imagePaths: savedPaths)
        document.wrappedValue.insert(node, under: parentID)
        selectedID.wrappedValue = node.id
        store.updateDocument(draft, document: document.wrappedValue)
        return true
    }

    /// Append more images to an existing gallery node (called from the
    /// property inspector). New images are saved under fresh UUIDs and
    /// appended to the node's `imagePaths`. Returns `false` if no
    /// bytes saved at all so the inspector can surface a single error.
    @discardableResult
    func appendGalleryImages(for nodeID: UUID, with imageBytesList: [Data]) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .gallery else { return false }

        var newPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID
                )
                newPaths.append(path)
            } catch { }
        }
        guard !newPaths.isEmpty else { return false }

        var existing = node.content.imagePaths ?? []
        existing.append(contentsOf: newPaths)
        node.content.imagePaths = existing
        document.wrappedValue.nodes[nodeID] = node
        store.updateDocument(draft, document: document.wrappedValue)
        return true
    }

    /// Remove the image at `index` from a gallery node. The underlying
    /// file is deleted only if no other node still references the same
    /// path (mirrors `deleteUnreferencedAssetPaths`).
    func removeGalleryImage(for nodeID: UUID, at index: Int) {
        guard var node = document.wrappedValue.nodes[nodeID],
              node.type == .gallery,
              var paths = node.content.imagePaths,
              index >= 0, index < paths.count else { return }
        let removed = paths.remove(at: index)
        node.content.imagePaths = paths
        document.wrappedValue.nodes[nodeID] = node
        if !Self.assetPathIsReferenced(removed, in: document.wrappedValue) {
            LocalCanvasAssetStore.delete(relativePath: removed)
        }
        store.updateDocument(draft, document: document.wrappedValue)
    }

    /// Replace the image bytes for an existing image node. The new file is
    /// written under the node's own ID, so duplicated nodes that initially
    /// shared a path get their own file on first replacement (no clobbering
    /// the original's image).
    @discardableResult
    func replaceImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .image else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.content.localImagePath = path
            document.wrappedValue.nodes[nodeID] = node
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Carousel item placement

    private func isCarousel(_ parentID: UUID?) -> Bool {
        guard let parentID else { return false }
        return document.wrappedValue.nodes[parentID]?.type == .carousel
    }

    private func nextCarouselItemOrigin(parentID: UUID?, size: CGSize) -> CGPoint {
        guard let parentID,
              let carousel = document.wrappedValue.nodes[parentID],
              carousel.type == .carousel else {
            return CGPoint(x: 32, y: 80)
        }

        let gap: Double = 12
        let leading: Double = 16
        let maxX = carousel.childrenIDs.compactMap { childID -> Double? in
            guard let maxX = document.wrappedValue.nodes[childID]?.frame.cgRect.maxX else {
                return nil
            }
            return Double(maxX)
        }.max()
        let x = (maxX.map { $0 + gap }) ?? leading
        let y = max(12, (carousel.frame.height - Double(size.height)) / 2)
        return CGPoint(x: x, y: y)
    }

    private func carouselTextItem(parentID: UUID?) -> CanvasNode {
        var node = CanvasNode.defaultText(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 112, height: 44)),
            size: CGSize(width: 112, height: 44)
        )
        node.content.text = "Item"
        node.style.backgroundColorHex = "#FFFFFF"
        node.style.cornerRadius = 22
        node.style.borderWidth = 1
        node.style.borderColorHex = "#E5E5EA"
        node.style.fontWeight = .semibold
        node.style.fontSize = 16
        node.style.textAlignment = .center
        return node
    }

    private func carouselContainerItem(parentID: UUID?) -> CanvasNode {
        CanvasNode.defaultContainer(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 144, height: 88)),
            size: CGSize(width: 144, height: 88)
        )
    }

    private func carouselIconItem(parentID: UUID?) -> CanvasNode {
        CanvasNode.defaultIcon(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 72, height: 72)),
            size: CGSize(width: 72, height: 72)
        )
    }

    // MARK: - Container background

    /// Save picked bytes as the *container's* background image. Mirrors
    /// the page-background flow but writes to a per-node deterministic
    /// filename (`container_<UUID>.jpg`). Updates only the
    /// `style.backgroundImagePath` field; the rest of the node is
    /// untouched.
    @discardableResult
    func setContainerBackgroundImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .container else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveContainerBackground(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.style.backgroundImagePath = path
            document.wrappedValue.nodes[nodeID] = node
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    /// Remove the container's background image — delete the file and
    /// unset the path so the canvas renders just the color again.
    func clearContainerBackgroundImage(for nodeID: UUID) {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .container else { return }
        if let path = node.style.backgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        node.style.backgroundImagePath = nil
        document.wrappedValue.nodes[nodeID] = node
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Page background

    /// Save picked image bytes as the page background and update the
    /// document's `pageBackgroundImagePath`. Filename is fixed per draft
    /// (`page_background.jpg`) so replacing always overwrites cleanly.
    @discardableResult
    func setPageBackgroundImage(_ data: Data) -> Bool {
        do {
            let path = try LocalCanvasAssetStore.savePageBackground(
                data,
                draftID: draft.id
            )
            document.wrappedValue.pageBackgroundImagePath = path
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    /// Clear the page background image — delete the file and unset the
    /// path so the canvas renders only the color again.
    func clearPageBackgroundImage() {
        if let path = document.wrappedValue.pageBackgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        document.wrappedValue.pageBackgroundImagePath = nil
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Selection-driven mutations

    func deleteSelected() {
        guard let id = selectedID.wrappedValue else { return }
        let removedAssetPaths = Self.assetPaths(inSubtreeRootedAt: id, document: document.wrappedValue)
        document.wrappedValue.remove(id)
        deleteUnreferencedAssetPaths(removedAssetPaths)
        selectedID.wrappedValue = nil
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.delete()
    }

    func duplicateSelected() {
        guard let id = selectedID.wrappedValue else { return }
        if let newID = document.wrappedValue.duplicate(id) {
            copyImageAssetsForDuplicatedSubtree(rootedAt: newID)
            selectedID.wrappedValue = newID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.duplicate()
        }
    }

    func bringSelectedToFront() {
        guard let id = selectedID.wrappedValue else { return }
        document.wrappedValue.bringToFront(id)
        store.updateDocument(draft, document: document.wrappedValue)
    }

    func sendSelectedBackward() {
        guard let id = selectedID.wrappedValue else { return }
        document.wrappedValue.sendBackward(id)
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Templates

    func saveTemplate(named name: String) -> Bool {
        do {
            _ = try TemplateStore(context: context).createTemplate(
                name: name,
                document: document.wrappedValue
            )
            return true
        } catch {
            return false
        }
    }

    /// Apply a saved template to this draft. On success replaces the
    /// document and clears selection; the caller is responsible for
    /// resetting any view-only flags (legacyDraft / sheets) and firing
    /// the success haptic post-transition cues — see `onAppliedSuccess`.
    func applyTemplate(_ template: ProfileTemplate, onAppliedSuccess: () -> Void) -> Bool {
        do {
            let appliedDocument = try TemplateStore(context: context).apply(template, to: draft)
            document.wrappedValue = appliedDocument
            selectedID.wrappedValue = nil
            CucuHaptics.success()
            onAppliedSuccess()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Asset housekeeping

    /// After a duplicate, the copied image nodes initially point at the
    /// original nodes' files because `ProfileDocument.duplicate` is a pure
    /// model clone. Give each copied image node its own deterministic asset
    /// path so later replace/delete operations stay node-local.
    func copyImageAssetsForDuplicatedSubtree(rootedAt rootID: UUID) {
        for nodeID in document.wrappedValue.subtree(rootedAt: rootID) {
            guard var node = document.wrappedValue.nodes[nodeID] else { continue }

            switch node.type {
            case .image:
                guard let currentPath = node.content.localImagePath,
                      !currentPath.isEmpty else { continue }
                do {
                    let copiedPath = try LocalCanvasAssetStore.copyImage(
                        from: currentPath,
                        draftID: draft.id,
                        nodeID: nodeID
                    )
                    node.content.localImagePath = copiedPath
                    document.wrappedValue.nodes[nodeID] = node
                } catch {
                    // If the source file is missing, keep the copied node's path
                    // as-is so the renderer shows its existing placeholder.
                }
            case .gallery:
                guard let currentPaths = node.content.imagePaths,
                      !currentPaths.isEmpty else { continue }
                // Each gallery image gets its own fresh asset UUID under
                // the new node so per-image replace/delete stays node-local.
                var copied: [String] = []
                for original in currentPaths {
                    let assetID = UUID()
                    do {
                        let path = try LocalCanvasAssetStore.copyImage(
                            from: original,
                            draftID: draft.id,
                            nodeID: assetID
                        )
                        copied.append(path)
                    } catch {
                        // Source missing — preserve the path so the
                        // gallery's count stays right; the renderer
                        // will show a placeholder for the missing tile.
                        copied.append(original)
                    }
                }
                node.content.imagePaths = copied
                document.wrappedValue.nodes[nodeID] = node
            default:
                break
            }
        }
    }

    static func assetPaths(inSubtreeRootedAt rootID: UUID, document: ProfileDocument) -> Set<String> {
        var paths: Set<String> = []
        for nodeID in document.subtree(rootedAt: rootID) {
            guard let node = document.nodes[nodeID] else { continue }
            if let path = node.content.localImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let path = node.style.backgroundImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let galleryPaths = node.content.imagePaths {
                for p in galleryPaths where !p.isEmpty { paths.insert(p) }
            }
        }
        return paths
    }

    func deleteUnreferencedAssetPaths(_ paths: Set<String>) {
        for path in paths where !Self.assetPathIsReferenced(path, in: document.wrappedValue) {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
    }

    static func assetPathIsReferenced(_ path: String, in document: ProfileDocument) -> Bool {
        if document.pageBackgroundImagePath == path {
            return true
        }
        return document.nodes.values.contains { node in
            if node.content.localImagePath == path { return true }
            if node.style.backgroundImagePath == path { return true }
            if let gallery = node.content.imagePaths, gallery.contains(path) { return true }
            return false
        }
    }

    // MARK: - Internals

    /// Where a new node lands:
    ///   • Selected `.container` → directly into that container.
    ///   • Selected `.carousel`   → directly into that horizontal strip.
    ///   • Selected carousel child → as a sibling item in that carousel.
    ///   • Otherwise               → page root.
    /// Mirrors the rule used for the AddNodeSheet's banner so the
    /// "Adding to:" hint matches reality.
    func parentForInsertion() -> UUID? {
        guard let sid = selectedID.wrappedValue,
              let node = document.wrappedValue.nodes[sid] else {
            return nil
        }
        switch node.type {
        case .container:
            return sid
        case .carousel:
            return sid
        default:
            return carouselAncestor(containing: sid)
        }
    }

    /// Return the carousel that owns `id`, or nil when the selected node
    /// is outside all carousels.
    private func carouselAncestor(containing id: UUID) -> UUID? {
        var current: UUID? = id
        while let nodeID = current,
              let parentID = document.wrappedValue.parent(of: nodeID) {
            if document.wrappedValue.nodes[parentID]?.type == .carousel {
                return parentID
            }
            current = parentID
        }
        return nil
    }
}
