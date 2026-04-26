import PhotosUI
import SwiftUI

enum CanvasSectionPreset: String, CaseIterable, Identifiable {
    case hero
    case interests
    case wall
    case journal
    case bulletin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero: return "Hero Section"
        case .interests: return "Interests/Tags"
        case .wall: return "Wall Placeholder"
        case .journal: return "Journal Placeholder"
        case .bulletin: return "Bulletin Placeholder"
        }
    }

    var subtitle: String {
        switch self {
        case .hero: return "Avatar, display name, bio, and a small badge."
        case .interests: return "Editable title plus tag-style chips."
        case .wall: return "A local-only message area mockup."
        case .journal: return "Editable journal card placeholders."
        case .bulletin: return "A short update-style section."
        }
    }

    var symbol: String {
        switch self {
        case .hero: return "person.crop.circle"
        case .interests: return "tag"
        case .wall: return "bubble.left.and.bubble.right"
        case .journal: return "book.pages"
        case .bulletin: return "megaphone"
        }
    }
}

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
    var onPickImage: (Data) -> Bool
    /// Avatar = a square image node with `clipShape: .circle`. Same
    /// disk-save path as `onPickImage`; the host is responsible for
    /// flipping the clip shape so the result is a true profile-pic
    /// circle out of the box.
    var onPickAvatar: (Data) -> Bool
    var onPickGallery: ([Data]) -> Bool
    var onPickSection: (CanvasSectionPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerSelection: PhotosPickerItem?
    @State private var avatarSelection: PhotosPickerItem?
    @State private var gallerySelection: [PhotosPickerItem] = []
    @State private var pickerLoading = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            List {
                destinationHeader

                // — Basic primitives the user reaches for first —
                Section {
                    Button {
                        onPickType(.text)
                        dismiss()
                    } label: {
                        rowLabel(symbol: "textformat", title: "Text",
                                 subtitle: "A line or paragraph of text.")
                    }
                    Button {
                        onPickType(.container)
                        dismiss()
                    } label: {
                        rowLabel(symbol: "rectangle", title: "Container",
                                 subtitle: "A rectangular area you can nest other elements inside.")
                    }
                    PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
                        rowLabel(symbol: "photo", title: "Image",
                                 subtitle: pickerLoading
                                    ? "Loading…"
                                    : "Pick a photo from your library.")
                    }
                    .disabled(pickerLoading)
                } header: {
                    CucuSectionLabel(text: "Basic")
                }

                // — Identity / social: the things a profile page is
                //   actually for. Avatar uses a separate picker
                //   selection so it doesn't clash with the plain
                //   Image picker above.
                Section {
                    PhotosPicker(selection: $avatarSelection, matching: .images, photoLibrary: .shared()) {
                        rowLabel(symbol: "person.crop.circle.fill", title: "Avatar",
                                 subtitle: pickerLoading
                                    ? "Loading…"
                                    : "A circular profile photo — square frame, circle clip.")
                    }
                    .disabled(pickerLoading)

                    Button {
                        onPickType(.link)
                        dismiss()
                    } label: {
                        rowLabel(symbol: "link", title: "Link",
                                 subtitle: "Profile link card — pill, button, badge, more.")
                    }

                    PhotosPicker(
                        selection: $gallerySelection,
                        maxSelectionCount: 12,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        rowLabel(symbol: "rectangle.grid.2x2", title: "Gallery",
                                 subtitle: pickerLoading
                                    ? "Loading…"
                                    : "Multiple photos in a grid, row, or collage.")
                    }
                    .disabled(pickerLoading)
                } header: {
                    CucuSectionLabel(text: "Social / Profile")
                }

                // — Decorative props — small visual flourishes —
                Section {
                    Button {
                        onPickType(.icon)
                        dismiss()
                    } label: {
                        rowLabel(symbol: "star.fill", title: "Icon",
                                 subtitle: "A cute symbol — pick a style family + glyph.")
                    }
                    Button {
                        onPickType(.divider)
                        dismiss()
                    } label: {
                        rowLabel(symbol: "scribble", title: "Divider",
                                 subtitle: "Decorative break — sparkle, lace, ribbon, more.")
                    }
                } header: {
                    CucuSectionLabel(text: "Decor")
                }

                if let pickerError {
                    Text(pickerError)
                        .font(.cucuSans(12, weight: .medium))
                        .foregroundStyle(Color.cucuCherry)
                }

                // — Pre-built section templates — drop-in groups —
                Section {
                    ForEach(CanvasSectionPreset.allCases) { preset in
                        Button {
                            onPickSection(preset)
                            dismiss()
                        } label: {
                            rowLabel(
                                symbol: preset.symbol,
                                title: preset.title,
                                subtitle: preset.subtitle
                            )
                        }
                    }
                } header: {
                    CucuSectionLabel(text: "Sections")
                }
            }
            .listStyle(.insetGrouped)
            .cucuFormBackdrop()
            .cucuSheetTitle("Add Element")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
            }
            .onChange(of: gallerySelection) { _, newItems in
                guard !newItems.isEmpty else { return }
                pickerLoading = true
                pickerError = nil
                Task {
                    var bytes: [Data] = []
                    for item in newItems {
                        do {
                            if let data = try await item.loadTransferable(type: Data.self) {
                                bytes.append(data)
                            }
                        } catch {
                            // Best effort — skip the unreadable item.
                        }
                    }
                    await MainActor.run {
                        if bytes.isEmpty {
                            pickerError = "Couldn't read those photos."
                            pickerLoading = false
                            gallerySelection = []
                        } else if onPickGallery(bytes) {
                            dismiss()
                        } else {
                            pickerError = "Couldn't save the gallery images."
                            pickerLoading = false
                            gallerySelection = []
                        }
                    }
                }
            }
            .onChange(of: pickerSelection) { _, newItem in
                guard let newItem else { return }
                loadAndApplyImage(item: newItem, save: onPickImage, resetState: { pickerSelection = nil })
            }
            .onChange(of: avatarSelection) { _, newItem in
                guard let newItem else { return }
                loadAndApplyImage(item: newItem, save: onPickAvatar, resetState: { avatarSelection = nil })
            }
        }
    }

    /// Shared loader for the Image and Avatar PhotosPicker rows —
    /// they only differ in which save closure runs once the bytes
    /// are read. Pulling the duplicated `loadTransferable` block
    /// into a single helper keeps the two pickers from drifting.
    private func loadAndApplyImage(
        item: PhotosPickerItem,
        save: @escaping (Data) -> Bool,
        resetState: @escaping () -> Void
    ) {
        pickerLoading = true
        pickerError = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        if save(data) {
                            dismiss()
                        } else {
                            pickerError = "Couldn't save that image."
                            pickerLoading = false
                            resetState()
                        }
                    }
                } else {
                    await MainActor.run {
                        pickerError = "Couldn't read that image."
                        pickerLoading = false
                        resetState()
                    }
                }
            } catch {
                await MainActor.run {
                    pickerError = "Couldn't read that image."
                    pickerLoading = false
                    resetState()
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
                    .foregroundStyle(Color.cucuInkSoft)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding to")
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(Color.cucuInkFaded)
                        .textCase(.uppercase)
                    Text(destination == .container ? "Selected Container" : "Page")
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private func rowLabel(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.cucuInkSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cucuSerif(16, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Text(subtitle)
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
