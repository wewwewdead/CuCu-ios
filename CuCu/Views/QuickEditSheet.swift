import PhotosUI
import SwiftUI
import UIKit

/// Friendly profile-personalization sheet. It edits the same
/// `ProfileDocument` the canvas owns, but stages text changes locally
/// and commits them together on Save / dismissal so Quick Edit behaves
/// like a form instead of a design inspector.
struct QuickEditSheet: View {
    @Binding var document: ProfileDocument
    let draft: ProfileDraft
    let store: DraftStore
    let onEditCanvas: () -> Void
    let onPublish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chrome = AppChromeStore.shared

    @State private var displayName = ""
    @State private var handle = ""
    @State private var bio = ""
    @State private var about = ""
    @State private var favorites: [String] = Array(repeating: "", count: 5)
    @State private var links: [QuickEditProfileMapper.LinkValue] = []
    @State private var music: [QuickEditProfileMapper.MusicValue] = []
    @State private var note = ""

    @State private var avatarPicker: PhotosPickerItem?
    @State private var avatarLoading = false
    @State private var avatarError: String?
    @State private var publishValidationMessage: String?

    @FocusState private var focused: Field?
    private enum Field { case name, handle, bio, about, note }

    private var isRemixDraft: Bool {
        draft.remixSourceUsername?.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        editorialMasthead
                        if showsCustomProfileNotice {
                            customProfileNotice
                        }
                        introSection
                        aboutSection
                        favoritesSection
                        linksSection
                        musicSection
                        notesSection
                        actionRow
                        endOfFormColophon
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
            .tint(chrome.theme.inkPrimary)
            .cucuRefinedNav(isRemixDraft ? "Make it yours" : "Quick Edit")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        flush()
                        dismiss()
                    }
                    .font(.cucuSans(15, weight: .semibold))
                    .foregroundStyle(chrome.theme.inkPrimary)
                }
            }
        }
        .onAppear { hydrate() }
        .onDisappear { flush() }
        .onChange(of: avatarPicker) { _, newValue in
            if let newValue { handlePickedAvatar(newValue) }
        }
    }

    /// Editorial masthead in the same vocabulary the feed and thread
    /// pages use: a tracked-mono spec line on the leading edge, a
    /// printer's-folio identifier on the trailing edge, and a
    /// Caprasimo display title with a cherry fleuron — scrolls with
    /// the content rather than pinning, so the sheet reads as a
    /// notebook spread that gives the form its own opening real
    /// estate.
    private var editorialMasthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.cucuCherry)
                        .frame(width: 5, height: 5)
                    Text(isRemixDraft ? "REMIX · QUICK EDIT" : "PROFILE · QUICK EDIT")
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2.4)
                        .foregroundStyle(chrome.theme.inkMuted)
                }
                Spacer(minLength: 8)
                Text(isRemixDraft ? "№ REMIX" : "№ DRAFT")
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2.4)
                    .foregroundStyle(chrome.theme.inkFaded)
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(isRemixDraft ? "Make it yours" : "Quick Edit")
                    .font(.custom("Caprasimo-Regular", size: 32))
                    .foregroundStyle(chrome.theme.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private var introSection: some View {
        formCard(title: "Your intro") {
            avatarRow

            field(label: "Display name") {
                TextField("Your name", text: $displayName)
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .handle }
            }

            field(label: "Status") {
                TextField("@yourname", text: $handle)
                    .focused($focused, equals: .handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focused = .bio }
            }

            field(label: "Short bio") {
                TextEditor(text: $bio)
                    .focused($focused, equals: .bio)
                    .frame(minHeight: 68, maxHeight: 110)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var aboutSection: some View {
        formCard(title: "About you") {
            missingSectionHint(.about)
            field(label: "About") {
                TextEditor(text: $about)
                    .focused($focused, equals: .about)
                    .frame(minHeight: 92, maxHeight: 150)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var favoritesSection: some View {
        formCard(title: "Favorites") {
            missingSectionHint(.favorites)
            ForEach(favorites.indices, id: \.self) { index in
                field(label: "Favorite \(index + 1)") {
                    TextField("Add a favorite", text: $favorites[index])
                }
            }
        }
    }

    private var linksSection: some View {
        formCard(title: "Links") {
            missingSectionHint(.links)
            ForEach($links) { $link in
                VStack(spacing: 8) {
                    field(label: "Label") {
                        TextField("Portfolio, shop, socials", text: $link.label)
                    }
                    field(label: "URL") {
                        TextField("https://", text: $link.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if isInvalidURL(link.url) {
                        validationText("Use a full link that starts with http:// or https://.")
                    }
                }
            }
        }
    }

    private var musicSection: some View {
        formCard(title: "Music") {
            missingSectionHint(.music)
            ForEach($music) { $track in
                VStack(spacing: 8) {
                    field(label: "Track or playlist") {
                        TextField("Now playing", text: $track.title)
                    }
                    field(label: "Music link") {
                        TextField("Spotify, Apple Music, SoundCloud", text: $track.url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if isInvalidURL(track.url) {
                        validationText("Use a full music link that starts with http:// or https://.")
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        formCard(title: "Notes") {
            missingSectionHint(.notes)
            field(label: "Simple note") {
                TextEditor(text: $note)
                    .focused($focused, equals: .note)
                    .frame(minHeight: 76, maxHeight: 130)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            if let publishValidationMessage {
                validationText(publishValidationMessage)
            }

            Button {
                flush()
                dismiss()
            } label: {
                Label("Save", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(primaryActionStyle)

            Text("Need finer control? Edit on canvas.")
                .font(.cucuSans(12, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    flush()
                    dismiss()
                    onEditCanvas()
                } label: {
                    Label("Edit on canvas", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(secondaryActionStyle)

                Button {
                    if let message = firstValidationMessage {
                        publishValidationMessage = message
                        return
                    }
                    publishValidationMessage = nil
                    flush()
                    dismiss()
                    onPublish()
                } label: {
                    Label("Publish", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(secondaryActionStyle)
            }
        }
    }

    /// Closing flourish — single fleuron between two hairline rules
    /// and a handwritten Caveat sign-off below. Same vocabulary the
    /// feed and thread close on, so the sheet ends with the same
    /// notebook-spread voice instead of a hard-edged form bottom.
    private var endOfFormColophon: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
                Text("❦")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cucuCherry)
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
            }
            Text("looking good — save when you're ready")
                .font(.custom("Caveat-Regular", size: 18))
                .foregroundStyle(chrome.theme.inkFaded)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var showsCustomProfileNotice: Bool {
        !QuickEditProfileMapper.hasFriendlyStructure(document)
    }

    private var customProfileNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(chrome.theme.inkFaded)
                .padding(.top, 2)
            Text("This style is extra custom. Quick Edit can save the basics; use canvas for finer control.")
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(noticeFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
        )
    }

    private var avatarRow: some View {
        HStack(spacing: 14) {
            avatarPreview
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Avatar")
                    .font(.cucuSans(13, weight: .semibold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                Text(avatarError ?? "Choose a profile photo.")
                    .font(.cucuSans(11, weight: .regular))
                    .foregroundStyle(avatarError == nil ? chrome.theme.cardInkFaded : Color.cucuCherry)
                    .lineLimit(2)
            }

            Spacer()

            PhotosPicker(selection: $avatarPicker, matching: .images) {
                Text(avatarLoading ? "Saving..." : "Change")
                    .font(.cucuSans(13, weight: .semibold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(fieldRecess))
                    .overlay(Capsule().strokeBorder(chrome.theme.cardStroke, lineWidth: 1))
            }
            .disabled(avatarLoading)
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let path = currentAvatarPath, let url = LocalCanvasAssetStore.resolveURL(path),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                chrome.theme.pageColor
                Image(systemName: "person.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(chrome.theme.inkFaded)
            }
        }
    }

    private var currentAvatarPath: String? {
        guard let id = StructuredProfileLayout.roleID(.profileAvatar, in: document) else { return nil }
        return document.nodes[id]?.content.localImagePath
    }

    @ViewBuilder
    private func missingSectionHint(_ kind: QuickEditProfileMapper.SectionKind) -> some View {
        if !QuickEditProfileMapper.hasEditableSection(kind, in: document) {
            Text("Add this by typing here. Leave it blank to keep it off your card.")
                .font(.cucuSans(12, weight: .regular))
                .foregroundStyle(chrome.theme.cardInkFaded)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func validationText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.cucuSans(12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.cucuCherry)
    }

    private func formCard<Content: View>(title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.cucuSans(17, weight: .bold))
                .foregroundStyle(chrome.theme.cardInkPrimary)
            content()
        }
        .padding(16)
        .background(chrome.theme.cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
        )
    }

    private func field<Content: View>(label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.cucuMono(10, weight: .medium))
                .tracking(2)
                .foregroundStyle(chrome.theme.cardInkFaded)
            content()
                .font(.cucuSans(15, weight: .regular))
                .foregroundStyle(chrome.theme.cardInkPrimary)
                .tint(chrome.theme.inkPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(fieldRecess)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
                )
        }
    }

    /// Subtle ink-against-card recess for input pills. Mirrors the
    /// `replyBarFill` idiom on the thread page so inputs across the
    /// app read as the same surface family — flips polarity by mood
    /// so dark themes get a faint highlight and light themes get a
    /// faint shadow instead of a hard-coded fill.
    private var fieldRecess: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    /// Soft fill for the "extra custom profile" notice — quieter than
    /// the form cards so the warning sits as advisory copy, not a
    /// second card register.
    private var noticeFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    private var primaryActionStyle: CucuFilledActionButtonStyle {
        CucuFilledActionButtonStyle(theme: chrome.theme)
    }

    private var secondaryActionStyle: CucuSecondaryActionButtonStyle {
        CucuSecondaryActionButtonStyle(theme: chrome.theme)
    }

    private func hydrate() {
        let values = QuickEditProfileMapper.read(from: document)
        displayName = values.displayName
        handle = values.handle
        bio = values.bio
        about = values.about
        favorites = paddedStrings(values.favorites, count: 5)
        links = paddedLinks(values.links, count: 3)
        music = paddedMusic(values.music, count: 2)
        note = values.note
    }

    private func flush() {
        var values = QuickEditProfileMapper.Values()
        values.displayName = displayName
        values.handle = handle
        values.bio = bio
        values.about = about
        values.favorites = favorites
        values.links = links
        values.music = music
        values.note = note

        var next = document
        QuickEditProfileMapper.apply(values, to: &next)
        guard next != document else {
            store.updateDocument(draft, document: document)
            return
        }
        document = next
        store.updateDocument(draft, document: next)
    }

    private var firstValidationMessage: String? {
        if links.contains(where: { isInvalidURL($0.url) }) {
            return "Fix your link URLs before publishing."
        }
        if music.contains(where: { isInvalidURL($0.url) }) {
            return "Fix your music links before publishing."
        }
        return nil
    }

    private func isInvalidURL(_ value: String) -> Bool {
        !QuickEditProfileMapper.isValidEditableURL(value)
    }

    private func paddedStrings(_ values: [String], count: Int) -> [String] {
        Array((values + Array(repeating: "", count: count)).prefix(count))
    }

    private func paddedLinks(_ values: [QuickEditProfileMapper.LinkValue],
                             count: Int) -> [QuickEditProfileMapper.LinkValue] {
        var result = Array(values.prefix(count))
        while result.count < count {
            result.append(QuickEditProfileMapper.LinkValue())
        }
        return result
    }

    private func paddedMusic(_ values: [QuickEditProfileMapper.MusicValue],
                             count: Int) -> [QuickEditProfileMapper.MusicValue] {
        var result = Array(values.prefix(count))
        while result.count < count {
            result.append(QuickEditProfileMapper.MusicValue())
        }
        return result
    }

    private func handlePickedAvatar(_ item: PhotosPickerItem) {
        avatarLoading = true
        avatarError = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        avatarError = "Couldn't read that photo."
                        avatarLoading = false
                        avatarPicker = nil
                    }
                    return
                }
                await MainActor.run {
                    saveAvatar(data: data)
                    avatarLoading = false
                    avatarPicker = nil
                }
            } catch {
                await MainActor.run {
                    avatarError = "Couldn't load the photo."
                    avatarLoading = false
                    avatarPicker = nil
                }
            }
        }
    }

    private func saveAvatar(data: Data) {
        guard let id = StructuredProfileLayout.roleID(.profileAvatar, in: document),
              var node = document.nodes[id] else {
            avatarError = "No avatar slot in the current profile."
            return
        }
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: node.id
            )
            node.content.localImagePath = path
            document.nodes[id] = node
            document.renderRevision &+= 1
            store.updateDocument(draft, document: document)
            CucuHaptics.soft()
        } catch {
            avatarError = "Couldn't save that photo."
        }
    }
}

/// Filled pill that paints `inkPrimary` on `pageColor` — on light
/// themes that's deep ink on cream, on dark themes it inverts to
/// cream on coal so the primary action keeps its emphasis without
/// us hard-coding a palette.
private struct CucuFilledActionButtonStyle: ButtonStyle {
    let theme: AppChromeTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cucuSans(15, weight: .semibold))
            .foregroundStyle(theme.pageColor)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                Capsule().fill(theme.inkPrimary.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

/// Quieter capsule — theme-tinted recess fill, hairline stroke, and
/// `inkPrimary` text. Same surface family as the field recesses, so
/// the secondary actions read as part of the form chrome rather
/// than a second-tier brand button.
private struct CucuSecondaryActionButtonStyle: ButtonStyle {
    let theme: AppChromeTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.cucuSans(14, weight: .semibold))
            .foregroundStyle(theme.inkPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .background(
                Capsule().fill(secondaryFill.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(Capsule().strokeBorder(theme.cardStroke, lineWidth: 1))
    }

    private var secondaryFill: Color {
        theme.isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }
}
