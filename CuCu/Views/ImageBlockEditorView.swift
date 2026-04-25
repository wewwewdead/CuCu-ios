import SwiftUI
import PhotosUI

/// Save/Cancel sheet for editing an image block.
///
/// File ops are deferred until Save: replacing the image just stages
/// `pendingImageData` in @State, and only at Save time is the data written to
/// disk via `LocalAssetStore`. Cancel walks away with no side-effects, so the
/// user can never accidentally overwrite the original by dismissing.
///
/// The block ID is the file's stable identity — every save targets
/// `block_<id>.jpg`, so a replace overwrites cleanly with no orphan files.
struct ImageBlockEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var data: ImageBlockData
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var isLoading = false
    @State private var errorMessage: String?

    let theme: ProfileTheme
    let draftID: UUID
    let onSave: (ImageBlockData) -> Void

    init(initial: ImageBlockData,
         theme: ProfileTheme,
         draftID: UUID,
         onSave: @escaping (ImageBlockData) -> Void) {
        self._data = State(initialValue: initial)
        self.theme = theme
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
                    Text("Live preview")
                }

                Section("Image") {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(pendingImageData == nil && data.localImagePath.isEmpty
                              ? "Pick image"
                              : "Replace image",
                              systemImage: "photo")
                    }
                    if !data.caption.isEmpty || pendingImageData != nil || !data.localImagePath.isEmpty {
                        TextField("Caption (optional)", text: $data.caption, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Layout") {
                    Picker("Aspect ratio", selection: $data.aspectRatio) {
                        ForEach(ImageAspectRatio.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    Picker("Image fit", selection: $data.imageFit) {
                        ForEach(ImageFit.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(data.aspectRatio == .auto)
                    Picker("Width", selection: $data.widthStyle) {
                        ForEach(BlockWidthStyle.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Shape") {
                    StyleSliderRow(label: "Corner radius", value: $data.cornerRadius, range: 0...40)
                    StyleSliderRow(label: "Padding", value: $data.padding, range: 0...40)
                }

                Section("Background") {
                    ColorControlRow(label: "Color", hex: $data.backgroundColorHex, supportsAlpha: true)
                }
            }
            .navigationTitle("Edit Image")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .disabled(isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding()
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

    /// Renders the block on the actual page background so the user sees how
    /// it'll look in the final profile, including the pending image data.
    private var livePreview: some View {
        ZStack {
            Color(hex: theme.backgroundColorHex)

            previewBlockView
                .padding(.horizontal, theme.pageHorizontalPadding)
                .padding(.vertical, 24)
        }
        .frame(minHeight: 200)
    }

    @ViewBuilder
    private var previewBlockView: some View {
        if let data = pendingImageData,
           let img = LocalAssetStore.loadImage(data: data) {
            // Render the staged data as an inline preview that matches the
            // saved-block layout (same aspect/fit/width logic).
            previewWithImage(img.resizable())
        } else {
            // No pending change → render the saved block. If the file is
            // missing (e.g. block was just created with empty path), the
            // ImageBlockView's placeholder takes over.
            ProfileBlockView(block: .image(self.data))
        }
    }

    @ViewBuilder
    private func previewWithImage(_ img: Image) -> some View {
        let widthCap: CGFloat = data.widthStyle == .fill ? .infinity : 320
        let inner: AnyView = data.aspectRatio == .auto
            ? AnyView(
                img.aspectRatio(contentMode: .fit)
                    .frame(maxWidth: widthCap)
                    .clipShape(RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous))
            )
            : AnyView(
                Color.clear
                    .aspectRatio(data.aspectRatio.numericRatio, contentMode: .fit)
                    .overlay(img.aspectRatio(contentMode: data.imageFit.contentMode))
                    .frame(maxWidth: widthCap)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous))
            )
        inner
            .padding(data.padding)
            .background(
                RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous)
                    .fill(Color(hex: data.backgroundColorHex))
            )
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
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't read that photo. Please try again."
                }
            }
        }
    }

    private func commit() {
        // If there's no pending file change, just hand the data back as-is.
        guard let bytes = pendingImageData else {
            onSave(data)
            dismiss()
            return
        }
        do {
            let path = try LocalAssetStore.saveBlockImageData(
                bytes,
                draftID: draftID,
                blockID: data.id
            )
            data.localImagePath = path
            onSave(data)
            dismiss()
        } catch LocalAssetStore.SaveError.normalizationFailed {
            errorMessage = "We couldn't process that image. Try a different photo."
        } catch {
            errorMessage = "Couldn't save the image. Please try again."
        }
    }
}
