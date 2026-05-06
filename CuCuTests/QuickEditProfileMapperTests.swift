import Foundation
import Testing
@testable import CuCu

@MainActor
struct QuickEditProfileMapperTests {
    @Test func canReadAndWriteEachTemplateType() throws {
        let expected = sampleValues()

        for template in ProfileTemplate.allCases {
            var document = template.makeDocument(defaults: isolatedDefaults(for: template.rawValue))

            #expect(QuickEditProfileMapper.hasFriendlyStructure(document))

            QuickEditProfileMapper.apply(expected, to: &document)
            let actual = QuickEditProfileMapper.read(from: document)

            #expect(actual.displayName == expected.displayName)
            #expect(actual.handle == expected.handle)
            #expect(actual.bio == expected.bio)
            #expect(actual.about == expected.about)
            #expect(actual.favorites == expected.favorites)
            #expect(actual.links.map(\.label) == expected.links.map(\.label))
            #expect(actual.links.map(\.url) == expected.links.map(\.url))
            #expect(actual.music.map(\.title) == expected.music.map(\.title))
            #expect(actual.music.map(\.url) == expected.music.map(\.url))
            #expect(actual.note == expected.note)
        }
    }

    @Test func handlesMissingSectionsByAddingOnlyFilledGroups() throws {
        var document = ProfileDocument.structuredProfileBlank
        let originalSectionCount = QuickEditProfileMapper.sectionCardIDs(in: document).count
        var values = QuickEditProfileMapper.Values()
        values.about = "I like tiny websites and matcha."
        values.links = [
            .init(label: "Home", url: "https://example.com")
        ]
        values.music = [
            .init(title: "Playlist", url: "https://open.spotify.com/playlist/abc")
        ]

        QuickEditProfileMapper.apply(values, to: &document)
        let actual = QuickEditProfileMapper.read(from: document)

        #expect(actual.about == values.about)
        #expect(actual.links.map(\.url) == values.links.map(\.url))
        #expect(actual.music.map(\.url) == values.music.map(\.url))
        #expect(actual.note == "")
        #expect(QuickEditProfileMapper.sectionCardIDs(in: document).count >= originalSectionCount + 3)
    }

    @Test func handlesLegacyFreeformDocumentsWithoutCrashing() throws {
        var document = ProfileDocument.blank
        let legacyText = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 24, y: 80, width: 260, height: 80),
            content: NodeContent(text: "legacy personal text")
        )
        document.insert(legacyText, under: nil, onPage: 0)

        _ = QuickEditProfileMapper.read(from: document)

        var values = QuickEditProfileMapper.Values()
        values.about = "New safe intro"
        values.favorites = ["drawing", "rhythm games"]
        values.links = [.init(label: "Site", url: "https://example.com/me")]
        values.note = "A small note"

        QuickEditProfileMapper.apply(values, to: &document)
        let actual = QuickEditProfileMapper.read(from: document)

        #expect(actual.about == values.about)
        #expect(actual.favorites == values.favorites)
        #expect(actual.links.map(\.url) == values.links.map(\.url))
        #expect(actual.note == values.note)
    }

    @Test func clampsLongTextAndAllowsEmptyValues() throws {
        var document = ProfileDocument.structuredProfileBlank
        var values = QuickEditProfileMapper.Values()
        values.displayName = String(repeating: "A", count: ProfileHeader.maxFullNameLength + 20)
        values.bio = String(repeating: "B", count: ProfileHeader.maxStatusLength + 20)
        values.about = String(repeating: "C", count: AboutContent.maxBodyLength + 20)
        values.favorites = [String(repeating: "D", count: FavoritesContent.maxItemLength + 20)]
        values.note = String(repeating: "E", count: NoteEntry.maxBodyLength + 20)
        values.links = [.init(label: String(repeating: "F", count: LinkEntry.maxLabelLength + 20), url: "")]

        QuickEditProfileMapper.apply(values, to: &document)
        let actual = QuickEditProfileMapper.read(from: document)

        #expect(actual.displayName.count == ProfileHeader.maxFullNameLength)
        #expect(actual.bio.count == ProfileHeader.maxStatusLength)
        #expect(actual.about.count == AboutContent.maxBodyLength)
        #expect(actual.favorites.first?.count == FavoritesContent.maxItemLength)
        #expect(actual.note.count == NoteEntry.maxBodyLength)
        #expect(actual.links.first?.label.count == LinkEntry.maxLabelLength)
        #expect(QuickEditProfileMapper.isValidEditableURL(""))
    }

    @Test func validatesEditableLinks() throws {
        #expect(QuickEditProfileMapper.isValidEditableURL("https://example.com/profile"))
        #expect(QuickEditProfileMapper.isValidEditableURL("http://example.com/profile"))
        #expect(!QuickEditProfileMapper.isValidEditableURL("example.com/profile"))
        #expect(!QuickEditProfileMapper.isValidEditableURL("javascript:alert(1)"))
    }

    private func sampleValues() -> QuickEditProfileMapper.Values {
        var values = QuickEditProfileMapper.Values()
        values.displayName = "Mina"
        values.handle = "@mina"
        values.bio = "Making a tiny cute corner."
        values.about = "Film cameras, soda tabs, and late-night anime."
        values.favorites = ["strawberry milk", "stickers", "episode 12"]
        values.links = [
            .init(label: "Portfolio", url: "https://example.com/mina"),
            .init(label: "Shop", url: "https://shop.example.com")
        ]
        values.music = [
            .init(title: "Current playlist", url: "https://open.spotify.com/playlist/abc")
        ]
        values.note = "Leave a nice note."
        return values
    }

    private func isolatedDefaults(for suffix: String) -> UserDefaults {
        let suiteName = "QuickEditProfileMapperTests.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
