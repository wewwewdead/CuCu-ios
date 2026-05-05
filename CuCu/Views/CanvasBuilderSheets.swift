import SwiftUI

/// All of the `.sheet` / `.fullScreenCover` modifiers consolidated into
/// one `ViewModifier`. Lifted out of `ProfileCanvasBuilderView`'s body
/// so it reads as canvas + overlay + toolbar + sheets-via-modifier
/// rather than the 200+ lines of stacked sheet modifiers it used to be.
///
/// Behavior is identical to the previous inline modifier stack — the
/// presentation flags live in `CanvasSheetCoordinator` and the
/// document mutations route through `CanvasMutator`.
struct CanvasBuilderSheetsModifier: ViewModifier {
    @Binding var document: ProfileDocument
    @Binding var selectedID: UUID?
    let selectedTextRangeByNodeID: [UUID: NSRange]
    let draft: ProfileDraft
    @Bindable var sheets: CanvasSheetCoordinator
    let mutator: CanvasMutator
    let addDestination: AddNodeSheet.Destination
    let isStructured: Bool
    let editingPageIndex: Int

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $sheets.showAddSheet) {
                AddNodeSheet(
                    destination: addDestination,
                    isStructured: isStructured,
                    onPickType: { type in mutator.addNode(of: type) },
                    onPickImage: { data in mutator.addImageNode(from: data) },
                    onPickAvatar: { data in mutator.addAvatarNode(from: data) },
                    onPickGallery: { dataList in mutator.addGalleryNode(from: dataList) },
                    onPickSection: { preset in
                        CanvasPresetBuilder.addSectionPreset(
                            preset,
                            document: $document,
                            selectedID: $selectedID,
                            draft: draft,
                            store: mutator.store,
                            rootPageIndex: editingPageIndex
                        )
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(
                isPresented: $sheets.showInspector,
                onDismiss: { sheets.handleInspectorDismiss(document: document) }
            ) {
                if let id = selectedID {
                    PropertyInspectorView(
                        document: $document,
                        selectedID: id,
                        selectedTextRange: selectedTextRangeByNodeID[id],
                        onCommit: { doc in
                            var normalized = doc
                            StructuredProfileLayout.normalize(&normalized)
                            document = normalized
                            mutator.store.updateDocument(draft, document: normalized)
                        },
                        onReplaceImage: { nodeID, data in mutator.replaceImage(for: nodeID, with: data) },
                        onSetContainerBackground: { nodeID, data in
                            mutator.setContainerBackgroundImage(for: nodeID, with: data)
                        },
                        onClearContainerBackground: { nodeID in
                            mutator.clearContainerBackgroundImage(for: nodeID)
                        },
                        onEditContainerBackground: { nodeID in
                            sheets.requestEditContainerEffects(for: nodeID)
                        },
                        onSetPageBackground: { pageIndex, data in
                            mutator.setPageBackgroundImage(data, pageIndex: pageIndex)
                        },
                        onClearPageBackground: { pageIndex in
                            mutator.clearPageBackgroundImage(pageIndex: pageIndex)
                        },
                        onAppendGalleryImages: { nodeID, dataList in
                            mutator.appendGalleryImages(for: nodeID, with: dataList)
                        },
                        onRemoveGalleryImage: { nodeID, index in
                            mutator.removeGalleryImage(for: nodeID, at: index)
                        }
                    )
                    // Compact bottom sheet: starts at ~30% of screen so the
                    // canvas stays visible. User can drag up to medium / large
                    // for more controls. `presentationBackgroundInteraction`
                    // keeps the canvas tap/drag-able while the sheet is at
                    // small or medium — that's how the live preview actually
                    // works without forcing the user to dismiss the inspector
                    // every time they want to nudge a node.
                    .presentationDetents([.fraction(0.3), .medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                }
            }
            .sheet(
                isPresented: $sheets.showPageBackgroundSheet,
                onDismiss: { sheets.handlePageBackgroundDismiss() }
            ) {
                PageBackgroundSheet(
                    document: $document,
                    pageIndex: editingPageIndex,
                    onPickImage: { data in mutator.setPageBackgroundImage(data, pageIndex: editingPageIndex) },
                    onClearImage: { mutator.clearPageBackgroundImage(pageIndex: editingPageIndex) },
                    onCommit: {
                        // Normalize so adaptive hero text colors
                        // recompute when the user picks a new page
                        // background. The hero's name / @username /
                        // bio with `textColorAuto = true` get their
                        // hex rewritten by `applyAdaptiveHeroTextColors`
                        // inside `normalize`, which only runs here on
                        // a manual commit cycle.
                        StructuredProfileLayout.normalize(&document)
                        mutator.store.updateDocument(draft, document: document)
                    },
                    onEditEffects: { sheets.requestEditPageEffects() }
                )
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
            .sheet(isPresented: $sheets.showLayersSheet) {
                LayersPanelView(
                    document: document,
                    selectedID: $selectedID,
                    onDeleteSelected: { mutator.deleteSelected() },
                    onBringToFront: { mutator.bringSelectedToFront() },
                    onSendBackward: { mutator.sendSelectedBackward() }
                )
                .equatable()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
            .sheet(isPresented: $sheets.showThemePickerSheet) {
                ThemePickerSheet(mutator: mutator, document: document)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $sheets.showBackgroundEffectsSheet) {
                BackgroundEffectsSheet(
                    title: "Edit Page Image",
                    blur: Binding(
                        get: { page(at: editingPageIndex).backgroundBlur },
                        set: { newValue in
                            updatePage(at: editingPageIndex) { page in
                                page.backgroundBlur = newValue
                            }
                        }
                    ),
                    vignette: Binding(
                        get: { page(at: editingPageIndex).backgroundVignette },
                        set: { newValue in
                            updatePage(at: editingPageIndex) { page in
                                page.backgroundVignette = newValue
                            }
                        }
                    ),
                    onCommit: { mutator.store.updateDocument(draft, document: document) }
                )
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
            .sheet(
                isPresented: $sheets.showContainerBackgroundEffectsSheet,
                onDismiss: { sheets.handleContainerEffectsDismiss() }
            ) {
                if let id = sheets.containerEffectsTargetID,
                   document.nodes[id]?.type == .container {
                    BackgroundEffectsSheet(
                        title: "Edit Container Image",
                        blur: containerBlurBinding(id: id),
                        vignette: containerVignetteBinding(id: id),
                        onCommit: { mutator.store.updateDocument(draft, document: document) }
                    )
                    .presentationDetents([.fraction(0.3), .medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                }
            }
            .sheet(isPresented: $sheets.showPublishSheet) {
                PublishSheet(
                    draft: draft,
                    document: document,
                    onViewPublished: { username in
                        // Push the public viewer onto the same nav stack
                        // after the publish sheet dismisses. Using
                        // `publishedViewerUsername` as a binding-driven
                        // navigation trigger keeps the logic in one place
                        // for both "View Profile" right after publish and
                        // "View Published" from the overflow menu.
                        sheets.publishedViewerUsername = username
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $sheets.showOpenProfileSheet) {
                OpenPublishedProfileSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(
                isPresented: Binding(
                    get: { sheets.shareProfileUsername != nil },
                    set: { if !$0 { sheets.shareProfileUsername = nil } }
                )
            ) {
                if let username = sheets.shareProfileUsername {
                    ProfileShareSheet(username: username, document: document)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
            .fullScreenCover(
                isPresented: $sheets.showPreview,
                onDismiss: {
                    // Mirrors the page-background → effects chain:
                    // arm `pendingShowPublishSheet` from the cover's
                    // `onPublish`, then promote it to the live publish
                    // sheet once the cover finishes its dismissal
                    // animation. Replaces the previous fixed 350ms
                    // `asyncAfter` shim, which was a guess at how long
                    // SwiftUI's "can't present from a view that's being
                    // dismissed" guard takes to clear.
                    if sheets.pendingShowPublishSheet {
                        sheets.pendingShowPublishSheet = false
                        sheets.showPublishSheet = true
                    }
                }
            ) {
                // Preview lives in `.fullScreenCover` (not `.sheet`) so
                // it really does fill the screen — the user is checking
                // what visitors see, not skimming a quick form.
                CanvasPreviewView(
                    document: document,
                    onClose: { sheets.showPreview = false },
                    onPublish: {
                        // Arm the chain and dismiss the cover; the
                        // `onDismiss` above promotes the pending flag to
                        // the live publish sheet.
                        sheets.pendingShowPublishSheet = true
                        sheets.showPreview = false
                    }
                )
            }
    }

    private func page(at index: Int) -> PageStyle {
        guard document.pages.indices.contains(index) else {
            return document.pages.first ?? PageStyle()
        }
        return document.pages[index]
    }

    private func updatePage(at index: Int, _ update: (inout PageStyle) -> Void) {
        guard document.pages.indices.contains(index) else { return }
        update(&document.pages[index])
        document.syncLegacyFieldsFromFirstPage()
    }

    /// Two-way binding into a container node's `style.backgroundBlur`.
    /// Lifted into a helper because the inline closure inside the sheet
    /// modifier wouldn't capture `id` cleanly otherwise.
    private func containerBlurBinding(id: UUID) -> Binding<Double?> {
        Binding(
            get: { document.nodes[id]?.style.backgroundBlur },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.backgroundBlur = newValue
                document.nodes[id] = node
            }
        )
    }

    private func containerVignetteBinding(id: UUID) -> Binding<Double?> {
        Binding(
            get: { document.nodes[id]?.style.backgroundVignette },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.backgroundVignette = newValue
                document.nodes[id] = node
            }
        )
    }
}
