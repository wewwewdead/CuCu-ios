import SwiftUI
import PhotosUI

/// Page-level theme editor presented from the builder.
///
/// Mirrors `BlockEditorView`'s Save/Cancel pattern: the editor holds local
/// state so the user can dismiss without committing partial changes. The
/// background image is staged in memory (`pendingImageData`) and only written
/// to disk on Save — Cancel walks away with no side-effects.
struct ThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var theme: ProfileTheme
    @State private var pickerItem: PhotosPickerItem?
    /// New image data picked but not yet written. Cleared on Save or Cancel.
    @State private var pendingImageData: Data?
    /// User tapped "Remove background image" — defer the file delete to Save.
    @State private var shouldRemoveBackground = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    let draftID: UUID
    let onSave: (ProfileTheme) -> Void

    init(initial: ProfileTheme,
         draftID: UUID,
         onSave: @escaping (ProfileTheme) -> Void) {
        self._theme = State(initialValue: initial)
        self.draftID = draftID
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    livePreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    CucuSectionLabel(text: "Live preview")
                }

                Section {
                    ColorControlRow(label: "Color", hex: $theme.backgroundColorHex, supportsAlpha: false)
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(
                            previewBackgroundImage == nil ? "Add image" : "Replace image",
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .font(.cucuSerif(15, weight: .semibold))
                    }
                    if previewBackgroundImage != nil {
                        Button(role: .destructive) {
                            shouldRemoveBackground = true
                            pendingImageData = nil
                            errorMessage = nil
                        } label: {
                            Label("Remove image", systemImage: "trash")
                                .font(.cucuSerif(15, weight: .semibold))
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.cucuSans(12, weight: .medium))
                            .foregroundStyle(Color.cucuCherry)
                    }
                } header: {
                    CucuSectionLabel(text: "Background")
                }

                Section {
                    ColorControlRow(label: "Color", hex: $theme.defaultTextColorHex, supportsAlpha: false)
                    FontPickerView(label: "Font", selection: $theme.defaultFontName)
                } header: {
                    CucuSectionLabel(text: "Text")
                }

                Section {
                    StyleSliderRow(label: "Page padding", value: $theme.pageHorizontalPadding, range: 0...60)
                    StyleSliderRow(label: "Block spacing", value: $theme.blockSpacing, range: 0...60)
                } header: {
                    CucuSectionLabel(text: "Layout")
                }
            }
            .cucuFormBackdrop()
            .cucuSheetTitle("Theme")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .font(.cucuSerif(16, weight: .bold))
                        .disabled(isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            loadPickedImage(newItem)
        }
    }

    // MARK: - Preview

    private var livePreview: some View {
        ZStack {
            Color(hex: theme.backgroundColorHex)

            if let img = previewBackgroundImage {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: theme.blockSpacing) {
                Text("Sample heading")
                    .font(.system(size: 24, weight: .semibold, design: theme.defaultFontName.design))
                    .foregroundStyle(Color(hex: theme.defaultTextColorHex))
                Text("A paragraph of sample text that lives on your page background.")
                    .font(.system(size: 15, design: theme.defaultFontName.design))
                    .foregroundStyle(Color(hex: theme.defaultTextColorHex))
            }
            .padding(.horizontal, theme.pageHorizontalPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 200)
        .clipped()
    }

    /// Resolves the image to render in the preview, accounting for staged
    /// changes that haven't been committed to disk yet.
    private var previewBackgroundImage: Image? {
        if shouldRemoveBackground { return nil }
        if let data = pendingImageData {
            return LocalAssetStore.loadImage(data: data)
        }
        if let path = theme.backgroundImagePath {
            return LocalAssetStore.loadImage(relativePath: path)
        }
        return nil
    }

    // MARK: - Actions

    private func loadPickedImage(_ item: PhotosPickerItem) {
        isLoading = true
        errorMessage = nil
        Task {
            defer {
                Task { @MainActor in
                    isLoading = false
                    pickerItem = nil
                }
            }
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        errorMessage = "Couldn't read that photo. Please try a different one."
                    }
                    return
                }
                await MainActor.run {
                    pendingImageData = bytes
                    shouldRemoveBackground = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't read that photo. Please try again."
                }
            }
        }
    }

    private func commit() {
        // Save first; only mutate theme/disk after a successful normalization
        // so a failed pick never replaces an existing background.
        if let bytes = pendingImageData {
            do {
                let path = try LocalAssetStore.saveBackgroundImageData(bytes, draftID: draftID)
                theme.backgroundImagePath = path
            } catch LocalAssetStore.SaveError.normalizationFailed {
                errorMessage = "We couldn't process that image. Try a different photo."
                return
            } catch {
                errorMessage = "Couldn't save the background image. Please try again."
                return
            }
        } else if shouldRemoveBackground, let existing = theme.backgroundImagePath {
            LocalAssetStore.delete(relativePath: existing)
            theme.backgroundImagePath = nil
        }
        onSave(theme)
        dismiss()
    }
}
