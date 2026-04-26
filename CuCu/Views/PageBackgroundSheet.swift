import PhotosUI
import SwiftUI
import UIKit

/// Edits the page-level background — a fill color (always) plus an
/// optional image that overlays the color. Users can pick either, both,
/// or neither.
///
/// The color is bound directly to `document.pageBackgroundHex`. The image
/// flow is more involved: the `PhotosPickerItem` is loaded as `Data` then
/// handed to the host (`ProfileCanvasBuilderView`) which writes it to disk
/// via `LocalCanvasAssetStore.savePageBackground` and updates the
/// document's `pageBackgroundImagePath`.
struct PageBackgroundSheet: View {
    @Binding var document: ProfileDocument

    var onPickImage: (Data) -> Bool
    var onClearImage: () -> Void
    var onCommit: () -> Void
    /// Called when the user taps "Edit Image". The host is responsible
    /// for dismissing this sheet and presenting the standalone
    /// `BackgroundEffectsSheet` once the dismissal animation completes.
    var onEditEffects: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerSelection: PhotosPickerItem?
    @State private var pickerLoading = false
    @State private var pickerError: String?

    /// Pending crop work — set after the user picks a photo but
    /// before the cropper sheet has run. The cropper presents on top
    /// of this sheet (sheet-on-sheet works in iOS 16+) so the user
    /// stays in the page-background context throughout. Only after
    /// the cropper's Done do we forward the cropped bytes via
    /// `onPickImage`.
    @State private var pendingCropSource: PendingCropSource?

    private struct PendingCropSource: Identifiable {
        let id = UUID()
        let data: Data
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: pageWidthBinding, in: 240...640, step: 10) {
                        valueRow(title: "Width", value: "\(Int(document.pageWidth)) px")
                    }
                    .onChange(of: document.pageWidth) { _, _ in onCommit() }

                    Stepper(value: pageHeightBinding, in: 400...4_000, step: 50) {
                        valueRow(title: "Height", value: "\(Int(document.pageHeight)) px")
                    }
                    .onChange(of: document.pageHeight) { _, _ in onCommit() }
                } header: {
                    CucuSectionLabel(text: "Page")
                } footer: {
                    Text("The visible profile canvas uses this fixed page size. Root content that extends below the height keeps the page expanded so existing nodes remain visible.")
                        .font(.cucuSans(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }

                Section {
                    ColorPicker(selection: bgColorBinding.asColor()) {
                        Text("Background Color")
                            .font(.cucuSerif(15, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
                    }
                    .onChange(of: bgColorBinding.wrappedValue) { _, _ in onCommit() }
                } header: {
                    CucuSectionLabel(text: "Color")
                } footer: {
                    Text("Always applied. Shows through transparent areas of any image you add.")
                        .font(.cucuSans(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }

                Section {
                    if let path = document.pageBackgroundImagePath,
                       !path.isEmpty,
                       let preview = LocalCanvasAssetStore.loadUIImage(path) {
                        currentImageRow(preview: preview)
                        replaceButton
                        Button {
                            onEditEffects()
                        } label: {
                            Label("Edit Image", systemImage: "wand.and.stars")
                                .font(.cucuSerif(15, weight: .semibold))
                        }
                        Button(role: .destructive) {
                            onClearImage()
                        } label: {
                            Label("Reset Background Image", systemImage: "trash")
                                .font(.cucuSerif(15, weight: .semibold))
                        }
                    } else {
                        chooseButton
                    }

                    if let pickerError {
                        Text(pickerError)
                            .font(.cucuSans(12, weight: .medium))
                            .foregroundStyle(Color.cucuCherry)
                    }
                } header: {
                    CucuSectionLabel(text: "Image")
                } footer: {
                    Text("Optional. Image overlays the background color.")
                        .font(.cucuSans(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }

            }
            .cucuFormBackdrop()
            .cucuSheetTitle("Page Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSerif(16, weight: .bold))
                }
            }
            .onChange(of: pickerSelection) { _, newItem in
                guard let newItem else { return }
                pickerLoading = true
                pickerError = nil
                Task {
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            await MainActor.run {
                                // Hand the picked bytes to the cropper
                                // first; only after the user confirms
                                // does the cropped data flow out via
                                // `onPickImage`.
                                pendingCropSource = PendingCropSource(data: data)
                                pickerLoading = false
                                pickerSelection = nil
                            }
                        } else {
                            await MainActor.run {
                                pickerError = "Couldn't read that image."
                                pickerLoading = false
                                pickerSelection = nil
                            }
                        }
                    } catch {
                        await MainActor.run {
                            pickerError = "Couldn't read that image."
                            pickerLoading = false
                            pickerSelection = nil
                        }
                    }
                }
            }
            .sheet(item: $pendingCropSource) { source in
                ImageCropperSheet(
                    sourceData: source.data,
                    targetAspect: pageBackgroundAspect
                ) { croppedData in
                    if onPickImage(croppedData) {
                        pickerError = nil
                    } else {
                        pickerError = "Couldn't save that image. Try another photo."
                    }
                }
            }
        }
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.cucuSerif(15, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
            Spacer()
            CucuValuePill(text: value)
        }
    }

    private func currentImageRow(preview: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cucuInk, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Image set")
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Text("Tap Replace to change it")
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var chooseButton: some View {
        PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
            Label(pickerLoading ? "Loading…" : "Choose Image", systemImage: "photo")
                .font(.cucuSerif(15, weight: .semibold))
        }
        .disabled(pickerLoading)
    }

    private var replaceButton: some View {
        PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
            Label(pickerLoading ? "Loading…" : "Replace Image",
                  systemImage: "photo.on.rectangle.angled")
                .font(.cucuSerif(15, weight: .semibold))
        }
        .disabled(pickerLoading)
    }

    private var bgColorBinding: Binding<String> {
        Binding(
            get: { document.pageBackgroundHex },
            set: { document.pageBackgroundHex = $0 }
        )
    }

    private var pageWidthBinding: Binding<Double> {
        Binding(
            get: { document.pageWidth },
            set: { document.pageWidth = min(640, max(240, $0)) }
        )
    }

    private var pageHeightBinding: Binding<Double> {
        Binding(
            get: { document.pageHeight },
            set: { document.pageHeight = min(4_000, max(400, $0)) }
        )
    }

    /// Aspect ratio of the canvas where the page background will be
    /// shown. This follows the document's fixed page size so picked
    /// backgrounds match the page frame, not the current device window.
    private var pageBackgroundAspect: CGFloat {
        let width = max(1, CGFloat(document.pageWidth))
        let height = max(1, CGFloat(document.pageHeight))
        return width / height
    }
}
