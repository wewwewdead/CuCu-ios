import CoreGraphics
import Foundation

/// Pure-ish bridge between the friendly Quick Edit form and the canvas
/// document. It intentionally targets semantic structure by roles,
/// section-card names, and visible section titles instead of depending
/// on a separate model that the live canvas does not persist.
enum QuickEditProfileMapper {
    struct LinkValue: Hashable, Identifiable {
        var id: UUID
        var label: String
        var url: String

        init(id: UUID = UUID(), label: String = "", url: String = "") {
            self.id = id
            self.label = label
            self.url = url
        }

        var isBlank: Bool {
            label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct MusicValue: Hashable, Identifiable {
        var id: UUID
        var title: String
        var url: String

        init(id: UUID = UUID(), title: String = "", url: String = "") {
            self.id = id
            self.title = title
            self.url = url
        }

        var isBlank: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct Values: Hashable {
        var displayName = ""
        var handle = ""
        var bio = ""
        var about = ""
        var favorites: [String] = []
        var links: [LinkValue] = []
        var music: [MusicValue] = []
        var note = ""
    }

    enum SectionKind {
        case about
        case favorites
        case links
        case music
        case notes

        var title: String {
            switch self {
            case .about: return "About Me"
            case .favorites: return "Favorites"
            case .links: return "Links"
            case .music: return "Music"
            case .notes: return "Notes"
            }
        }

        var cardName: String {
            switch self {
            case .about: return "About Section"
            case .favorites: return "Favorites Section"
            case .links: return "Links Section"
            case .music: return "Music Section"
            case .notes: return "Notes Section"
            }
        }

        var keywords: [String] {
            switch self {
            case .about: return ["about", "intro", "bio"]
            case .favorites: return ["favorite", "favorites", "interest", "interests", "likes"]
            case .links: return ["links", "link", "platform", "social"]
            case .music: return ["music", "song", "songs", "playlist", "track", "listening", "now playing"]
            case .notes: return ["notes", "note", "journal", "entry", "bulletin", "wall", "status"]
            }
        }
    }

    static func read(from document: ProfileDocument) -> Values {
        var values = Values()
        values.displayName = readRoleText(.profileName, in: document) ?? ""
        values.handle = readRoleText(.profileMeta, in: document) ?? ""
        values.bio = readRoleText(.profileBio, in: document) ?? ""
        values.about = readBodyText(in: .about, from: document) ?? ""
        values.favorites = readListText(in: .favorites, from: document)
        values.links = readLinks(from: document)
        values.music = readMusic(from: document)
        values.note = readNote(from: document) ?? ""
        return values
    }

    static func apply(_ values: Values, to document: inout ProfileDocument) {
        let values = normalizedValues(values)
        writeRoleText(.profileName, text: values.displayName, in: &document)
        writeRoleText(.profileMeta, text: values.handle, in: &document)
        writeRoleText(.profileBio, text: values.bio, in: &document)

        if !trim(values.about).isEmpty || sectionCard(for: .about, in: document) != nil {
            writeBodyText(values.about, in: .about, document: &document)
        }

        let favorites = normalizedStrings(values.favorites, limit: 8)
        if !favorites.isEmpty || sectionCard(for: .favorites, in: document) != nil {
            writeListText(favorites, in: .favorites, document: &document)
        }

        let links = values.links.filter { !$0.isBlank }.prefix(4).map { $0 }
        if !links.isEmpty || sectionCard(for: .links, in: document) != nil || !allLinkNodes(in: document).isEmpty {
            writeLinks(Array(links), document: &document)
        }

        let music = values.music.filter { !$0.isBlank }.prefix(3).map { $0 }
        if !music.isEmpty || sectionCard(for: .music, in: document) != nil {
            writeMusic(Array(music), document: &document)
        }

        if !trim(values.note).isEmpty || sectionCard(for: .notes, in: document) != nil {
            writeNote(values.note, document: &document)
        }

        StructuredProfileLayout.normalize(&document)
    }

    static func hasFriendlyStructure(_ document: ProfileDocument) -> Bool {
        StructuredProfileLayout.roleID(.profileName, in: document) != nil ||
        StructuredProfileLayout.roleID(.profileMeta, in: document) != nil ||
        StructuredProfileLayout.roleID(.profileBio, in: document) != nil ||
        !sectionCardIDs(in: document).isEmpty
    }

    static func hasEditableSection(_ kind: SectionKind, in document: ProfileDocument) -> Bool {
        sectionCard(for: kind, in: document) != nil
    }

    nonisolated static func isValidEditableURL(_ value: String) -> Bool {
        let trimmed = trim(value)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return trimmed.isEmpty
        }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Hero

    private static func readRoleText(_ role: CanvasNodeRole, in document: ProfileDocument) -> String? {
        guard let id = StructuredProfileLayout.roleID(role, in: document) else { return nil }
        return document.nodes[id]?.content.text
    }

    private static func writeRoleText(_ role: CanvasNodeRole, text: String, in document: inout ProfileDocument) {
        guard let id = StructuredProfileLayout.roleID(role, in: document),
              var node = document.nodes[id] else { return }
        updateTextNode(&node, text: text)
        document.nodes[id] = node
    }

    // MARK: - Read sections

    private static func readBodyText(in kind: SectionKind, from document: ProfileDocument) -> String? {
        guard let cardID = sectionCard(for: kind, in: document) else { return nil }
        return contentTextIDs(in: cardID, document: document)
            .compactMap { document.nodes[$0]?.content.text }
            .map(trim)
            .first { !$0.isEmpty && !placeholderTexts.contains($0.lowercased()) }
    }

    private static func readListText(in kind: SectionKind, from document: ProfileDocument) -> [String] {
        guard let cardID = sectionCard(for: kind, in: document) else { return [] }
        return contentTextIDs(in: cardID, document: document)
            .compactMap { document.nodes[$0]?.content.text }
            .map(trim)
            .filter { !$0.isEmpty && !placeholderTexts.contains($0.lowercased()) }
            .prefix(8)
            .map { $0 }
    }

    private static func readLinks(from document: ProfileDocument) -> [LinkValue] {
        let scoped = sectionCard(for: .links, in: document).map {
            linkNodeIDs(in: $0, document: document)
        } ?? []
        let ids = scoped.isEmpty ? allLinkNodes(in: document) : scoped
        return ids.prefix(4).compactMap { id in
            guard let node = document.nodes[id] else { return nil }
            return LinkValue(label: node.content.text ?? "", url: node.content.url ?? "")
        }
    }

    private static func readMusic(from document: ProfileDocument) -> [MusicValue] {
        let scoped = sectionCard(for: .music, in: document).map {
            linkNodeIDs(in: $0, document: document)
        } ?? []
        let ids = scoped.isEmpty
            ? allLinkNodes(in: document).filter { id in
                guard let url = document.nodes[id]?.content.url else { return false }
                return looksLikeMusicURL(url)
            }
            : scoped
        return ids.prefix(3).compactMap { id in
            guard let node = document.nodes[id] else { return nil }
            return MusicValue(title: node.content.text ?? "", url: node.content.url ?? "")
        }
    }

    private static func readNote(from document: ProfileDocument) -> String? {
        if let cardID = sectionCard(for: .notes, in: document) {
            if let noteID = noteNodeIDs(in: cardID, document: document).first {
                return document.nodes[noteID]?.content.text
            }
            return readBodyText(in: .notes, from: document)
        }
        let noteID = document.nodes.values
            .filter { $0.type == .note }
            .sorted { nodeSortKey($0) < nodeSortKey($1) }
            .first?.id
        return noteID.flatMap { document.nodes[$0]?.content.text }
    }

    // MARK: - Write sections

    private static func writeBodyText(_ text: String,
                                      in kind: SectionKind,
                                      document: inout ProfileDocument) {
        let cardID = ensureSectionCard(kind, in: &document)
        let existing = contentTextIDs(in: cardID, document: document).first
        let id = existing ?? addTextNode(
            text: "",
            frame: NodeFrame(x: 16, y: 54, width: sectionContentWidth(cardID, document: document), height: 92),
            under: cardID,
            in: &document
        )
        guard var node = document.nodes[id] else { return }
        updateTextNode(&node, text: text)
        document.nodes[id] = node
    }

    private static func writeListText(_ items: [String],
                                      in kind: SectionKind,
                                      document: inout ProfileDocument) {
        let cardID = ensureSectionCard(kind, in: &document)
        var ids = contentTextIDs(in: cardID, document: document)
        for index in 0..<max(ids.count, items.count) {
            if index >= items.count {
                if index < ids.count, var node = document.nodes[ids[index]] {
                    updateTextNode(&node, text: "")
                    document.nodes[ids[index]] = node
                }
                continue
            }
            if index >= ids.count {
                ids.append(addChipNode(
                    text: "",
                    index: index,
                    under: cardID,
                    in: &document
                ))
            }
            guard var node = document.nodes[ids[index]] else { continue }
            updateTextNode(&node, text: items[index])
            document.nodes[ids[index]] = node
        }
    }

    private static func writeLinks(_ links: [LinkValue], document: inout ProfileDocument) {
        let cardID = ensureSectionCard(.links, in: &document)
        var ids = linkNodeIDs(in: cardID, document: document)
        for index in 0..<max(ids.count, links.count) {
            if index >= links.count {
                if index < ids.count, var node = document.nodes[ids[index]] {
                    updateTextNode(&node, text: "")
                    node.content.url = ""
                    document.nodes[ids[index]] = node
                }
                continue
            }
            if index >= ids.count {
                ids.append(addLinkNode(index: index, under: cardID, in: &document))
            }
            guard var node = document.nodes[ids[index]] else { continue }
            updateTextNode(&node, text: links[index].label)
            node.content.url = links[index].url
            document.nodes[ids[index]] = node
        }
    }

    private static func writeMusic(_ music: [MusicValue], document: inout ProfileDocument) {
        let cardID = ensureSectionCard(.music, in: &document)
        var ids = linkNodeIDs(in: cardID, document: document)
        for index in 0..<max(ids.count, music.count) {
            if index >= music.count {
                if index < ids.count, var node = document.nodes[ids[index]] {
                    updateTextNode(&node, text: "")
                    node.content.url = ""
                    document.nodes[ids[index]] = node
                }
                continue
            }
            if index >= ids.count {
                ids.append(addLinkNode(index: index, under: cardID, in: &document))
            }
            guard var node = document.nodes[ids[index]] else { continue }
            updateTextNode(&node, text: music[index].title)
            node.content.url = music[index].url
            document.nodes[ids[index]] = node
        }
    }

    private static func writeNote(_ text: String, document: inout ProfileDocument) {
        let cardID = ensureSectionCard(.notes, in: &document)
        let noteIDs = noteNodeIDs(in: cardID, document: document)
        if let id = noteIDs.first, var node = document.nodes[id] {
            updateTextNode(&node, text: text)
            node.content.noteTitle = node.content.noteTitle?.isEmpty == false ? node.content.noteTitle : "Notes"
            document.nodes[id] = node
            return
        }
        writeBodyText(text, in: .notes, document: &document)
    }

    // MARK: - Section discovery

    static func sectionCard(for kind: SectionKind, in document: ProfileDocument) -> UUID? {
        sectionCardIDs(in: document).first { id in
            let descriptor = sectionDescriptor(cardID: id, document: document)
            return kind.keywords.contains { descriptor.contains($0) }
        }
    }

    static func sectionCardIDs(in document: ProfileDocument) -> [UUID] {
        document.nodes.values
            .filter { node in
                if node.role == .sectionCard { return true }
                return node.type == .container &&
                node.role != .profileHero &&
                node.role?.isSystemOwned != true &&
                document.parent(of: node.id) == nil
            }
            .sorted { nodeSortKey($0) < nodeSortKey($1) }
            .map(\.id)
    }

    static func titleTextID(in cardID: UUID, document: ProfileDocument) -> UUID? {
        textNodeIDs(in: cardID, document: document)
            .sorted { lhs, rhs in
                guard let l = document.nodes[lhs], let r = document.nodes[rhs] else { return false }
                return nodeSortKey(l) < nodeSortKey(r)
            }
            .first
    }

    private static func sectionDescriptor(cardID: UUID, document: ProfileDocument) -> String {
        let name = document.nodes[cardID]?.name ?? ""
        let title = titleTextID(in: cardID, document: document)
            .flatMap { document.nodes[$0]?.content.text } ?? ""
        return "\(name) \(title)".lowercased()
    }

    private static func contentTextIDs(in cardID: UUID, document: ProfileDocument) -> [UUID] {
        let titleID = titleTextID(in: cardID, document: document)
        return textNodeIDs(in: cardID, document: document)
            .filter { $0 != titleID }
            .sorted { lhs, rhs in
                guard let l = document.nodes[lhs], let r = document.nodes[rhs] else { return false }
                return nodeSortKey(l) < nodeSortKey(r)
            }
    }

    private static func textNodeIDs(in rootID: UUID, document: ProfileDocument) -> [UUID] {
        document.subtree(rootedAt: rootID)
            .filter { id in
                guard id != rootID, let node = document.nodes[id] else { return false }
                return node.type == .text
            }
    }

    private static func linkNodeIDs(in rootID: UUID, document: ProfileDocument) -> [UUID] {
        document.subtree(rootedAt: rootID)
            .filter { id in document.nodes[id]?.type == .link }
            .sorted { lhs, rhs in
                guard let l = document.nodes[lhs], let r = document.nodes[rhs] else { return false }
                return nodeSortKey(l) < nodeSortKey(r)
            }
    }

    private static func noteNodeIDs(in rootID: UUID, document: ProfileDocument) -> [UUID] {
        document.subtree(rootedAt: rootID)
            .filter { id in document.nodes[id]?.type == .note }
            .sorted { lhs, rhs in
                guard let l = document.nodes[lhs], let r = document.nodes[rhs] else { return false }
                return nodeSortKey(l) < nodeSortKey(r)
            }
    }

    private static func allLinkNodes(in document: ProfileDocument) -> [UUID] {
        document.nodes.values
            .filter { $0.type == .link }
            .sorted { nodeSortKey($0) < nodeSortKey($1) }
            .map(\.id)
    }

    // MARK: - Section creation

    @discardableResult
    private static func ensureSectionCard(_ kind: SectionKind, in document: inout ProfileDocument) -> UUID {
        if let existing = sectionCard(for: kind, in: document) { return existing }
        let pageIndex = StructuredProfileLayout.primaryPageIndex(in: document) ?? 0
        let height: Double
        switch kind {
        case .about, .notes: height = 184
        case .favorites, .links, .music: height = 224
        }
        var card = StructuredProfileLayout.makeSectionCard(
            in: document,
            pageIndex: pageIndex,
            height: height,
            name: kind.cardName
        )
        card.style = NodeStyle(
            backgroundColorHex: "#FFFFFF",
            cornerRadius: 18,
            borderWidth: 1,
            borderColorHex: "#E7DED1"
        )
        document.insert(card, under: nil, onPage: pageIndex)
        _ = addTextNode(
            text: kind.title,
            frame: NodeFrame(x: 16, y: 16, width: sectionContentWidth(card.id, document: document), height: 28),
            under: card.id,
            in: &document,
            size: 22,
            weight: .bold
        )
        return card.id
    }

    @discardableResult
    private static func addTextNode(text: String,
                                    frame: NodeFrame,
                                    under parentID: UUID,
                                    in document: inout ProfileDocument,
                                    size: Double = 15,
                                    weight: NodeFontWeight = .regular) -> UUID {
        let node = CanvasNode(
            type: .text,
            frame: frame,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .system,
                fontWeight: weight,
                fontSize: size,
                textColorHex: "#1A140E",
                textAlignment: .leading,
                lineSpacing: 2
            ),
            content: NodeContent(text: text)
        )
        document.insert(node, under: parentID)
        return node.id
    }

    @discardableResult
    private static func addChipNode(text: String,
                                    index: Int,
                                    under parentID: UUID,
                                    in document: inout ProfileDocument) -> UUID {
        let col = Double(index % 2)
        let row = Double(index / 2)
        let gap: Double = 8
        let width = max(120, (sectionContentWidth(parentID, document: document) - gap) / 2)
        let node = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 16 + col * (width + gap), y: 58 + row * 42, width: width, height: 34),
            style: NodeStyle(
                backgroundColorHex: "#FBF6E9",
                cornerRadius: 17,
                borderWidth: 1,
                borderColorHex: "#E7DED1",
                fontFamily: .system,
                fontWeight: .semibold,
                fontSize: 13,
                textColorHex: "#1A140E",
                textAlignment: .center
            ),
            content: NodeContent(text: text)
        )
        document.insert(node, under: parentID)
        return node.id
    }

    @discardableResult
    private static func addLinkNode(index: Int,
                                    under parentID: UUID,
                                    in document: inout ProfileDocument) -> UUID {
        var node = CanvasNode.defaultLink(
            at: .init(x: 16, y: 54 + Double(index) * 56),
            size: .init(width: sectionContentWidth(parentID, document: document), height: 46)
        )
        node.content.text = ""
        node.content.url = ""
        document.insert(node, under: parentID)
        return node.id
    }

    // MARK: - Utilities

    private static let placeholderTexts: Set<String> = [
        "add your details",
        "write a quick note here.",
        "your link",
        "display name",
        "@username",
        "short bio, quote, status, or current thing."
    ]

    private static func normalizedValues(_ raw: Values) -> Values {
        var values = Values()
        values.displayName = clamped(trim(raw.displayName), maxLength: ProfileHeader.maxFullNameLength)
        values.handle = clamped(trim(raw.handle), maxLength: ProfileHeader.maxFullNameLength)
        values.bio = clamped(trim(raw.bio), maxLength: ProfileHeader.maxStatusLength)
        values.about = clamped(trim(raw.about), maxLength: AboutContent.maxBodyLength)
        values.favorites = raw.favorites.map {
            clamped(trim($0), maxLength: FavoritesContent.maxItemLength)
        }
        values.links = raw.links.map {
            LinkValue(
                id: $0.id,
                label: clamped(trim($0.label), maxLength: LinkEntry.maxLabelLength),
                url: clamped(trim($0.url), maxLength: 2048)
            )
        }
        values.music = raw.music.map {
            MusicValue(
                id: $0.id,
                title: clamped(trim($0.title), maxLength: FavoritesContent.maxItemLength),
                url: clamped(trim($0.url), maxLength: 2048)
            )
        }
        values.note = clamped(trim(raw.note), maxLength: NoteEntry.maxBodyLength)
        return values
    }

    private static func updateTextNode(_ node: inout CanvasNode, text: String) {
        let oldText = node.content.text ?? ""
        node.content.text = text
        node.content.reconcileTextStyleSpans(oldText: oldText, newText: text)
    }

    private static func normalizedStrings(_ values: [String], limit: Int) -> [String] {
        values
            .map(trim)
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func clamped(_ value: String, maxLength: Int) -> String {
        String(value.prefix(maxLength))
    }

    private static func looksLikeMusicURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("spotify.") ||
        lower.contains("music.apple.") ||
        lower.contains("soundcloud.") ||
        lower.contains("bandcamp.") ||
        lower.contains("youtube.") ||
        lower.contains("youtu.be")
    }

    private static func sectionContentWidth(_ cardID: UUID, document: ProfileDocument) -> Double {
        max(220, (document.nodes[cardID]?.frame.width ?? 326) - 32)
    }

    private static func nodeSortKey(_ node: CanvasNode) -> String {
        String(format: "%09.3f-%09.3f-%@", node.frame.y, node.frame.x, node.id.uuidString)
    }
}
