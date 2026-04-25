import PhotosUI
import SwiftUI

/// Choose a node type to add to the canvas.
///
/// `Container` and `Text` simply emit a type intent — the builder creates
/// the node. `Image` is a `PhotosPicker` so the system Photos sheet overlays
/// this sheet directly; once the user picks, we load `Data` via the
/// transferable API, dismiss, and hand the bytes to the builder.
struct AddNodeSheet: View {
    enum Destination: Equatable {
        case page
        case container
    }

    var destination: Destination
    var onPickType: (NodeType) -> Void
    var onPickImage: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerSelection: PhotosPickerItem?
    @State private var pickerLoading = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            List {
                destinationHeader

                Button {
                    onPickType(.container)
                    dismiss()
                } label: {
                    rowLabel(symbol: "rectangle", title: "Container",
                             subtitle: "A rectangular area you can nest other elements inside.")
                }

                Button {
                    onPickType(.text)
                    dismiss()
                } label: {
                    rowLabel(symbol: "textformat", title: "Text",
                             subtitle: "A line or paragraph of text.")
                }

                PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
                    rowLabel(symbol: "photo", title: "Image",
                             subtitle: pickerLoading
                                ? "Loading…"
                                : "Pick a photo from your library.")
                }
                .disabled(pickerLoading)

                if let pickerError {
                    Text(pickerError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Element")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: pickerSelection) { _, newItem in
                guard let newItem else { return }
                pickerLoading = true
                pickerError = nil
                Task {
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            // Hand off to the builder; it writes to disk and
                            // creates the node. Then close this sheet.
                            await MainActor.run {
                                onPickImage(data)
                                dismiss()
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
        }
    }

    /// Banner row showing where new items will land — page root or the
    /// currently selected container. Closes the loop on the user's
    /// nesting expectation: "if the destination is the container, dragging
    /// that container later will carry this new item with it."
    @ViewBuilder
    private var destinationHeader: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: destination == .container ? "rectangle.on.rectangle" : "doc")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding to")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(destination == .container ? "Selected Container" : "Page")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private func rowLabel(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 32, height: 32)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
