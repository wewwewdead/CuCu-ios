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

    var onPickImage: (Data) -> Void
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
                    ColorPicker("Background Color", selection: bgColorBinding.asColor())
                        .onChange(of: bgColorBinding.wrappedValue) { _, _ in onCommit() }
                } header: {
                    Text("Color")
                } footer: {
                    Text("Always applied. Shows through transparent areas of any image you add.")
                }

                Section {
                    if let path = document.pageBackgroundImagePath,
                       !path.isEmpty,
                       let url = LocalCanvasAssetStore.resolveURL(path),
                       let preview = UIImage(contentsOfFile: url.path) {
                        currentImageRow(preview: preview)
                        replaceButton
                        Button {
                            // Hand off to the host. It dismisses this
                            // sheet first, then presents
                            // `BackgroundEffectsSheet` once the
                            // dismissal animation finishes — so the
                            // user only ever sees one modal at a time.
                            onEditEffects()
                        } label: {
                            Label("Edit Image", systemImage: "wand.and.stars")
                        }
                        Button(role: .destructive) {
                            onClearImage()
                        } label: {
                            Label("Remove Image", systemImage: "trash")
                        }
                    } else {
                        chooseButton
                    }

                    if let pickerError {
                        Text(pickerError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Image")
                } footer: {
                    Text("Optional. Image overlays the background color.")
                }

            }
            .navigationTitle("Page Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                    onPickImage(croppedData)
                }
            }
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
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Image set")
                    .font(.subheadline.weight(.medium))
                Text("Tap Replace to change it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var chooseButton: some View {
        PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
            Label(pickerLoading ? "Loading…" : "Choose Image", systemImage: "photo")
        }
        .disabled(pickerLoading)
    }

    private var replaceButton: some View {
        PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
            Label(pickerLoading ? "Loading…" : "Replace Image",
                  systemImage: "photo.on.rectangle.angled")
        }
        .disabled(pickerLoading)
    }

    private var bgColorBinding: Binding<String> {
        Binding(
            get: { document.pageBackgroundHex },
            set: { document.pageBackgroundHex = $0 }
        )
    }

    /// Aspect ratio of the canvas where the page background will be
    /// shown — taken from the active scene's window so the cropper's
    /// crop window matches what the user will see on the page. Falls
    /// back to a portrait phone aspect if no window is available.
    private var pageBackgroundAspect: CGFloat {
        let bounds = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow?
            .bounds
        guard let bounds, bounds.width > 0, bounds.height > 0 else {
            return 9.0 / 19.5
        }
        return bounds.width / bounds.height
    }
}
