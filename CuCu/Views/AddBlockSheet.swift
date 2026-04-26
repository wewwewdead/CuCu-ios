import SwiftUI
import PhotosUI

/// Block-type chooser sheet.
///
/// Text creation is synchronous — tap and the block is added.
/// Image creation funnels through `PhotosPicker`: pick an image, write it to
/// `LocalAssetStore` under this draft's folder, then call back with the new
/// `ImageBlockData`. If the user cancels the system picker, no block is added.
struct AddBlockSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draftID: UUID
    let onAddText: () -> Void
    let onAddImage: (ImageBlockData) -> Void
    let onAddContainer: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Button {
                        onAddText()
                        dismiss()
                    } label: {
                        BlockOptionContent(
                            icon: "textformat",
                            title: "Text",
                            subtitle: "A paragraph, heading, or note"
                        )
                    }
                    .buttonStyle(.plain)

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        BlockOptionContent(
                            icon: "photo",
                            title: "Image",
                            subtitle: "A picture from your library"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)

                    Button {
                        onAddContainer()
                        dismiss()
                    } label: {
                        BlockOptionContent(
                            icon: "square.stack.3d.up",
                            title: "Container",
                            subtitle: "Group blocks into a row, column, or card"
                        )
                    }
                    .buttonStyle(.plain)

                    if let errorMessage {
                        InlineErrorBanner(message: errorMessage)
                    }

                    // Future block types (quote, gallery, link, video) plug in here.
                }
                .padding(20)
            }
            .background(Color.cucuPaper.ignoresSafeArea())
            .cucuSheetTitle("Add Block")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS) || os(visionOS)
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .tint(Color.cucuInk)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
            }
            .overlay {
                if isProcessing {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        #if os(iOS) || os(visionOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            handlePickedImage(newItem)
        }
    }

    private func handlePickedImage(_ item: PhotosPickerItem) {
        isProcessing = true
        errorMessage = nil
        Task {
            defer {
                Task { @MainActor in
                    isProcessing = false
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
                let blockID = UUID()
                let path = try LocalAssetStore.saveBlockImageData(
                    bytes,
                    draftID: draftID,
                    blockID: blockID
                )
                let block = ImageBlockData.newBlock(id: blockID, localImagePath: path)
                await MainActor.run {
                    onAddImage(block)
                    dismiss()
                }
            } catch LocalAssetStore.SaveError.normalizationFailed {
                await MainActor.run {
                    errorMessage = "We couldn't process that image. Try a different photo."
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't save the image. Please try again."
                }
            }
        }
    }
}

private struct InlineErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.cucuCherry)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.cucuSans(13, weight: .medium))
                .foregroundStyle(Color.cucuInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cucuShell.opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cucuCherry, lineWidth: 1)
        )
    }
}

private struct BlockOptionContent: View {
    let icon: String
    let title: String
    let subtitle: String

    /// Map the block's symbol to one of the editor's three node-kind tints
    /// so the option swatches feel consistent with the inspector and
    /// selection bar.
    private var kind: CucuNodeKind {
        switch icon {
        case "textformat":          return .text
        case "photo":               return .image
        default:                    return .container
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            CucuIconBadge(kind: kind, symbol: icon, size: 44, iconSize: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cucuSerif(18, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text(subtitle)
                    .font(.cucuSans(13, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.cucuInkFaded)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1)
        )
        .shadow(color: Color.cucuInk.opacity(0.10), radius: 6, y: 2)
    }
}
