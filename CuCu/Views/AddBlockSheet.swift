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
    @State private var chrome = AppChromeStore.shared

    let draftID: UUID
    let onAddText: () -> Void
    let onAddImage: (ImageBlockData) -> Void
    let onAddContainer: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                ScrollView {
                    VStack(spacing: 0) {
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
                        .buttonStyle(CucuRefinedRowButtonStyle())
                        CucuRefinedDivider()

                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            BlockOptionContent(
                                icon: "photo",
                                title: "Image",
                                subtitle: "A picture from your library"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessing)
                        CucuRefinedDivider()

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
                        .buttonStyle(CucuRefinedRowButtonStyle())

                        if let errorMessage {
                            InlineErrorBanner(message: errorMessage)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .cucuRefinedNav("Add Block")
            .tint(chrome.theme.inkPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSans(15, weight: .regular))
                        .foregroundStyle(chrome.theme.inkPrimary)
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
    @State private var chrome = AppChromeStore.shared

    private static let cherry = Color(red: 178/255, green: 42/255, blue: 74/255)

    var body: some View {
        Text(message)
            .font(.cucuSans(13, weight: .regular))
            .foregroundStyle(Self.cherry)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }
}

private struct BlockOptionContent: View {
    let icon: String
    let title: String
    let subtitle: String
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(chrome.theme.inkPrimary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cucuSans(16, weight: .bold))
                    .foregroundStyle(chrome.theme.inkPrimary)
                Text(subtitle)
                    .font(.cucuSans(13, weight: .regular))
                    .foregroundStyle(chrome.theme.inkFaded)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chrome.theme.inkFaded)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
