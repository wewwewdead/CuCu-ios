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
        case structuredPage
        case sectionCard
        case container
        /// User has a `.carousel` selected — new nodes become items in
        /// that horizontal strip.
        case carousel
    }

    var destination: Destination
    var isStructured: Bool = false
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
    @State private var chrome = AppChromeStore.shared
    @State private var pickerSelection: PhotosPickerItem?
    @State private var avatarSelection: PhotosPickerItem?
    @State private var gallerySelection: [PhotosPickerItem] = []
    @State private var pickerLoading = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        destinationHeader

                        if destination == .structuredPage {
                            // Cards section sits at the top because Section Card
                            // is the structured profile's primary editing unit.
                            sectionGroup(label: "Cards") {
                                refinedRow(symbol: "rectangle.inset.filled",
                                           title: "Section Card",
                                           subtitle: "A fitted profile card below your header.") {
                                    onPickType(.container)
                                    dismiss()
                                }
                            }
                        }

                        basicGroup
                        socialGroup
                        decorGroup

                        if let pickerError {
                            Text(pickerError)
                                .font(.cucuSans(13, weight: .regular))
                                .foregroundStyle(destructiveInk)
                                .padding(.horizontal, 4)
                        }

                        sectionGroup(label: "Sections") {
                            ForEach(Array(availablePresets.enumerated()), id: \.element.id) { index, preset in
                                refinedRow(
                                    symbol: preset.symbol,
                                    title: preset.title,
                                    subtitle: preset.subtitle
                                ) {
                                    onPickSection(preset)
                                    dismiss()
                                }
                                if index < availablePresets.count - 1 {
                                    rowDivider
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .tint(chrome.theme.inkPrimary)
            .cucuRefinedNav("Add Element")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSans(15, weight: .regular))
                        .foregroundStyle(chrome.theme.inkPrimary)
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

    /// Basic primitives — text, container, plain image.
    @ViewBuilder
    private var basicGroup: some View {
        sectionGroup(label: "Basic") {
            refinedRow(symbol: "textformat", title: "Text",
                       subtitle: "A line or paragraph of text.") {
                onPickType(.text)
                dismiss()
            }
            rowDivider
            if destination != .structuredPage {
                refinedRow(symbol: "rectangle", title: "Container",
                           subtitle: "A rectangular area you can nest other elements inside.") {
                    onPickType(.container)
                    dismiss()
                }
                rowDivider
            }
            PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
                refinedRowLabel(symbol: "photo", title: "Image",
                                subtitle: pickerLoading
                                    ? "Loading…"
                                    : "Pick a photo from your library.")
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
            .disabled(pickerLoading)
        }
    }

    /// Identity / social rows — avatar, link, gallery, carousel.
    @ViewBuilder
    private var socialGroup: some View {
        sectionGroup(label: "Social / Profile") {
            PhotosPicker(selection: $avatarSelection, matching: .images, photoLibrary: .shared()) {
                refinedRowLabel(symbol: "person.crop.circle.fill", title: "Avatar",
                                subtitle: pickerLoading
                                    ? "Loading…"
                                    : "A circular profile photo — square frame, circle clip.")
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
            .disabled(pickerLoading)
            rowDivider

            refinedRow(symbol: "link", title: "Link",
                       subtitle: "Profile link card — pill, button, badge, more.") {
                onPickType(.link)
                dismiss()
            }
            rowDivider

            PhotosPicker(
                selection: $gallerySelection,
                maxSelectionCount: 12,
                matching: .images,
                photoLibrary: .shared()
            ) {
                refinedRowLabel(symbol: "rectangle.grid.2x2", title: "Gallery",
                                subtitle: pickerLoading
                                    ? "Loading…"
                                    : "Multiple photos in a grid, row, or collage.")
            }
            .buttonStyle(CucuRefinedRowButtonStyle())
            .disabled(pickerLoading)
            rowDivider

            refinedRow(symbol: "rectangle.stack", title: "Carousel",
                       subtitle: "A horizontal strip for text, images, and other items.") {
                onPickType(.carousel)
                dismiss()
            }
            rowDivider

            refinedRow(symbol: "note.text", title: "Note",
                       subtitle: "Memo card — title, time, and a body of text.") {
                onPickType(.note)
                dismiss()
            }
        }
    }

    /// Decorative props — icon, divider.
    @ViewBuilder
    private var decorGroup: some View {
        sectionGroup(label: "Decor") {
            refinedRow(symbol: "star.fill", title: "Icon",
                       subtitle: "A cute symbol — pick a style family + glyph.") {
                onPickType(.icon)
                dismiss()
            }
            rowDivider
            refinedRow(symbol: "scribble", title: "Divider",
                       subtitle: "Decorative break — sparkle, lace, ribbon, more.") {
                onPickType(.divider)
                dismiss()
            }
        }
    }

    /// Banner row showing where new items will land — page root or the
    /// currently selected container. Closes the loop on the user's
    /// nesting expectation: "if the destination is the container, dragging
    /// that container later will carry this new item with it."
    /// Refined "Adding to" header — sits above the section list as a
    /// theme-aware card showing where new items will land.
    @ViewBuilder
    private var destinationHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: destinationSymbol)
                .foregroundStyle(chrome.theme.cardInkPrimary)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Adding to")
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded)
                Text(destinationLabel)
                    .font(.cucuSans(15, weight: .bold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chrome.theme.cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(chrome.theme.rule, lineWidth: 1)
        )
    }

    /// Section wrapper — a refined faded label sitting on the page
    /// above a card-grouped column of rows.
    @ViewBuilder
    private func sectionGroup<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(chrome.theme.cardColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chrome.theme.rule, lineWidth: 1)
            )
        }
    }

    /// Hairline rule between rows inside a card. Inset on the
    /// leading edge so the rule reads as the row's bottom rather
    /// than a full-card section break.
    private var rowDivider: some View {
        Rectangle()
            .fill(chrome.theme.rule)
            .frame(height: 1)
            .padding(.leading, 56)
    }

    /// Tappable refined row — used for any non-PhotosPicker entry
    /// in the section groups.
    @ViewBuilder
    private func refinedRow(
        symbol: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            refinedRowLabel(symbol: symbol, title: title, subtitle: subtitle)
        }
        .buttonStyle(CucuRefinedRowButtonStyle())
    }

    /// Shared row body. Used directly by `PhotosPicker` (which
    /// supplies its own button chrome) and indirectly via
    /// `refinedRow(...)` for tap-action rows.
    private func refinedRowLabel(
        symbol: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(chrome.theme.cardInkPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cucuSans(16, weight: .bold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                Text(subtitle)
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Cherry tone for the inline picker error.
    private var destructiveInk: Color {
        Color(red: 178 / 255, green: 42 / 255, blue: 74 / 255)
    }

    private var destinationSymbol: String {
        switch destination {
        case .container:    return "rectangle.on.rectangle"
        case .sectionCard:  return "rectangle.inset.filled"
        case .carousel:     return "rectangle.stack"
        case .structuredPage:return "person.crop.rectangle"
        case .page:         return "doc"
        }
    }

    private var destinationLabel: String {
        switch destination {
        case .container:    return "Selected Container"
        case .sectionCard:  return "Selected Section Card"
        case .carousel:     return "Carousel"
        case .structuredPage:return "Profile Page"
        case .page:         return "Page"
        }
    }

    private var availablePresets: [CanvasSectionPreset] {
        if isStructured {
            return CanvasSectionPreset.allCases.filter { $0 != .hero }
        }
        return CanvasSectionPreset.allCases
    }

}
