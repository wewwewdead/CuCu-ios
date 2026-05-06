import Foundation
import Testing
@testable import CuCu

@MainActor
struct RemixTransformerTests {
    @Test func personalContentIsStrippedButStyleSurvives() throws {
        var document = ProfileDocument.structuredProfileBlank
        document.pages[0].backgroundHex = "#112233"
        document.pages[0].backgroundPatternKey = "sparkles"
        document.syncLegacyFieldsFromFirstPage()

        setRole(.profileName, text: "Mina Park", in: &document)
        setRole(.profileMeta, text: "@mina", in: &document)
        setRole(.profileBio, text: "real personal status", in: &document)

        let aboutID = addAboutCard(to: &document)
        let linkID = addLink(to: &document, under: aboutID)
        let noteID = addNote(to: &document, under: aboutID)

        let remixed = RemixTransformer.remix(from: document)

        #expect(roleText(.profileName, in: remixed) == "Display Name")
        #expect(roleText(.profileMeta, in: remixed) == "@username")
        #expect(roleText(.profileBio, in: remixed) == "Short bio, quote, status, or current thing.")
        #expect(remixed.nodes[linkID]?.content.url == "")
        #expect(remixed.nodes[linkID]?.content.text == "your link")
        #expect(remixed.nodes[noteID]?.content.text == "Write a quick note here.")
        #expect(remixed.pages[0].backgroundHex == "#112233")
        #expect(remixed.pages[0].backgroundPatternKey == "sparkles")
        #expect(remixed.nodes[aboutID]?.style.backgroundColorHex == "#FFF7E6")
        #expect(remixed.nodes[aboutID]?.style.cornerRadius == 18)
    }

    @Test func remoteURLsAreRemovedFromEditableDraftSurfaces() throws {
        var document = ProfileDocument.structuredProfileBlank
        document.pages[0].backgroundImagePath = "https://example.com/page.jpg"
        document.pageBackgroundImagePath = "https://example.com/page.jpg"

        let image = CanvasNode(
            type: .image,
            frame: NodeFrame(x: 16, y: 340, width: 100, height: 100),
            style: NodeStyle(backgroundImagePath: "https://example.com/container.jpg"),
            content: NodeContent(localImagePath: "https://example.com/avatar.jpg")
        )
        let gallery = CanvasNode(
            type: .gallery,
            frame: NodeFrame(x: 16, y: 460, width: 320, height: 180),
            content: NodeContent(imagePaths: [
                "https://example.com/one.jpg",
                "https://example.com/two.jpg"
            ])
        )
        document.insert(image, under: nil, onPage: 0)
        document.insert(gallery, under: nil, onPage: 0)

        let remixed = RemixTransformer.remix(from: document)

        #expect(remixed.pages[0].backgroundImagePath == nil)
        #expect(remixed.pageBackgroundImagePath == nil)
        #expect(remixed.nodes[image.id]?.style.backgroundImagePath == nil)
        #expect(remixed.nodes[image.id]?.content.localImagePath == nil)
        #expect(remixed.nodes[gallery.id]?.content.imagePaths == [])
    }

    @Test func bundledDecorativeAssetsArePreserved() throws {
        var document = ProfileDocument.structuredProfileBlank
        document.pages[0].backgroundImagePath = "bundled:paper"
        document.pageBackgroundImagePath = "bundled:paper"

        let image = CanvasNode(
            type: .image,
            frame: NodeFrame(x: 16, y: 340, width: 100, height: 100),
            style: NodeStyle(backgroundImagePath: "bundled:container-paper"),
            content: NodeContent(localImagePath: "bundled:sticker")
        )
        let gallery = CanvasNode(
            type: .gallery,
            frame: NodeFrame(x: 16, y: 460, width: 320, height: 180),
            content: NodeContent(imagePaths: [
                "bundled:sticker-a",
                "https://example.com/photo.jpg"
            ])
        )
        document.insert(image, under: nil, onPage: 0)
        document.insert(gallery, under: nil, onPage: 0)

        let remixed = RemixTransformer.remix(from: document)

        #expect(remixed.pages[0].backgroundImagePath == "bundled:paper")
        #expect(remixed.pageBackgroundImagePath == "bundled:paper")
        #expect(remixed.nodes[image.id]?.style.backgroundImagePath == "bundled:container-paper")
        #expect(remixed.nodes[image.id]?.content.localImagePath == "bundled:sticker")
        #expect(remixed.nodes[gallery.id]?.content.imagePaths == ["bundled:sticker-a"])
    }

    @Test func sectionTitlesSurviveWhileSectionBodiesAreCleared() throws {
        var document = ProfileDocument.structuredProfileBlank
        let cardID = addAboutCard(to: &document)

        let remixed = RemixTransformer.remix(from: document)

        let textValues = document.subtree(rootedAt: cardID)
            .compactMap { remixed.nodes[$0]?.content.text }
        #expect(textValues.contains("About Me"))
        #expect(!textValues.contains("I live in Seoul and love film cameras."))
        #expect(textValues.contains("Add your details"))
    }

    @Test func remixDoesNotMutateSourceDocument() throws {
        var document = ProfileDocument.structuredProfileBlank
        document.heroAvatarURL = "https://example.com/avatar.jpg"
        setRole(.profileName, text: "Mina Park", in: &document)
        setRole(.profileBio, text: "private status", in: &document)
        let aboutID = addAboutCard(to: &document)
        let original = document

        let remixed = RemixTransformer.remix(from: document)

        #expect(document == original)
        #expect(document.heroAvatarURL == original.heroAvatarURL)
        #expect(document.nodes[aboutID]?.style.backgroundColorHex == "#FFF7E6")
        #expect(roleText(.profileName, in: document) == "Mina Park")
        #expect(roleText(.profileBio, in: document) == "private status")
        #expect(remixed != document)
    }

    private func setRole(_ role: CanvasNodeRole, text: String, in document: inout ProfileDocument) {
        guard let id = StructuredProfileLayout.roleID(role, in: document),
              var node = document.nodes[id] else { return }
        node.content.text = text
        document.nodes[id] = node
    }

    private func roleText(_ role: CanvasNodeRole, in document: ProfileDocument) -> String? {
        guard let id = StructuredProfileLayout.roleID(role, in: document) else { return nil }
        return document.nodes[id]?.content.text
    }

    private func addAboutCard(to document: inout ProfileDocument) -> UUID {
        var card = StructuredProfileLayout.makeSectionCard(
            in: document,
            pageIndex: 0,
            height: 184,
            name: "About Section"
        )
        card.style = NodeStyle(
            backgroundColorHex: "#FFF7E6",
            cornerRadius: 18,
            borderWidth: 1,
            borderColorHex: "#E9C46A"
        )
        document.insert(card, under: nil, onPage: 0)
        let title = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 16, y: 16, width: 320, height: 28),
            content: NodeContent(text: "About Me")
        )
        let body = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 16, y: 56, width: 320, height: 80),
            content: NodeContent(text: "I live in Seoul and love film cameras.")
        )
        document.insert(title, under: card.id)
        document.insert(body, under: card.id)
        return card.id
    }

    private func addLink(to document: inout ProfileDocument, under parentID: UUID) -> UUID {
        var link = CanvasNode.defaultLink()
        link.content.text = "Portfolio"
        link.content.url = "https://example.com/mina"
        document.insert(link, under: parentID)
        return link.id
    }

    private func addNote(to document: inout ProfileDocument, under parentID: UUID) -> UUID {
        var note = CanvasNode.defaultNote()
        note.content.text = "private journal text"
        note.content.noteTitle = "Mina Notes"
        note.content.noteTimestamp = "yesterday"
        document.insert(note, under: parentID)
        return note.id
    }
}
