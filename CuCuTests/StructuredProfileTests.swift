import Foundation
import Testing
@testable import CuCu

@MainActor
struct StructuredProfileCodableTests {
    @Test func emptyProfileRoundTrips() throws {
        let profile = StructuredProfile()

        let decoded = try roundTrip(profile)

        #expect(decoded == profile)
        #expect(decoded.schemaVersion == 2)
    }

    @Test func fullProfileWithEveryContainerKindRoundTrips() throws {
        let createdAt = Date(timeIntervalSince1970: 1_776_800_000)
        let profile = StructuredProfile(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            header: ProfileHeader(
                fullName: "Mina Park",
                status: "making tiny pages",
                profilePhotoPath: "draft/profile.jpg"
            ),
            containers: [
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    kind: .about,
                    variantKey: "about.minimal",
                    height: 168,
                    content: .about(AboutContent(title: "About Me", body: "I collect paper scraps."))
                ),
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    kind: .favorites,
                    variantKey: "favorites.grid",
                    height: 216,
                    content: .favorites(FavoritesContent(title: "Favorites", items: ["tea", "film cameras"]))
                ),
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    kind: .notes,
                    variantKey: "notes.cards",
                    height: 240,
                    content: .notes(NotesContent(
                        title: "Notes",
                        entries: [NoteEntry(
                            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                            body: "Short entry",
                            createdAt: createdAt
                        )]
                    ))
                ),
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                    kind: .photo,
                    variantKey: "photo.grid",
                    height: 288,
                    content: .photo(PhotoContent(
                        title: "Photos",
                        photos: [PhotoEntry(
                            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                            localPath: "draft/photo.jpg",
                            remoteURL: nil,
                            caption: "Window light"
                        )]
                    ))
                ),
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                    kind: .links,
                    variantKey: "links.pill",
                    height: 168,
                    content: .links(LinksContent(
                        title: "Links",
                        links: [LinkEntry(
                            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                            label: "Portfolio",
                            url: "https://example.com"
                        )]
                    ))
                ),
                ProfileContainer(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                    kind: .music,
                    variantKey: "music.cards",
                    height: 240,
                    content: .music(MusicContent(
                        title: "Music",
                        tracks: [MusicTrack(
                            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                            url: "https://open.spotify.com/track/abc",
                            label: "A Song",
                            artworkURL: "https://example.com/art.jpg"
                        )]
                    ))
                )
            ],
            themeKey: "mintGarden",
            pageBackgroundHex: "#D8E9C9",
            pageBackgroundPatternKey: "meadow",
            pageBackgroundImagePath: "draft/background.jpg",
            pageBackgroundBlur: 8,
            pageBackgroundVignette: 0.4,
            pageBackgroundImageOpacity: 0.8
        )

        let decoded = try roundTrip(profile)

        #expect(decoded == profile)
    }

    @Test func seededProfileHasFiveEmptyDefaultContainersAndNoMusic() throws {
        let profile = StructuredProfile.seeded

        #expect(profile.containers.map(\.kind) == [.about, .favorites, .photo, .links, .notes])
        #expect(profile.containers.map(\.variantKey) == [
            "about.minimal",
            "favorites.list",
            "photo.grid",
            "links.pill",
            "notes.timeline"
        ])
        let allSeededContainersAreEmpty = profile.containers.allSatisfy { $0.content.isEmpty }
        #expect(allSeededContainersAreEmpty)
        #expect(!profile.containers.contains { $0.kind == .music })
    }
}

@MainActor
struct StructuredProfileForwardCompatibilityTests {
    @Test func unknownContainerKindDecodesAsEmptyAboutStub() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000099",
          "kind": "futureKind",
          "variantKey": "futureKind.primary",
          "height": 216,
          "content": {
            "futureField": "new clients may write this"
          }
        }
        """.data(using: .utf8)!

        let container = try JSONDecoder().decode(ProfileContainer.self, from: json)

        #expect(container.id == UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)
        #expect(container.kind == .about)
        #expect(container.variantKey == "about.minimal")
        #expect(container.height == 216)
        guard case .about(let content) = container.content else {
            Issue.record("unknown kind should fall back to about content")
            return
        }
        #expect(content.title == "About Me")
        #expect(content.body.isEmpty)
    }

    @Test func unknownVariantKeyFallsBackToFirstVariantForKind() throws {
        for kind in ContainerKind.allCases {
            let container = ProfileContainer(
                kind: kind,
                variantKey: "\(kind.rawValue).future",
                height: 216,
                content: .empty(for: kind)
            )

            #expect(container.variantKey == ContainerVariantRegistry.defaultVariantKey(for: kind))
        }
    }

    @Test func unknownVariantKeyFallsBackOnDecode() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000010",
          "kind": "favorites",
          "variantKey": "favorites.future",
          "height": 216,
          "content": {
            "title": "Favorites",
            "items": ["one"]
          }
        }
        """.data(using: .utf8)!

        let container = try JSONDecoder().decode(ProfileContainer.self, from: json)

        #expect(container.kind == .favorites)
        #expect(container.variantKey == "favorites.list")
    }
}

@MainActor
struct StructuredProfileLimitTests {
    @Test func collectionLimitsAreEnforcedOnInit() throws {
        let photos = PhotoContent(
            photos: (0..<20).map { PhotoEntry(localPath: "photo-\($0).jpg") }
        )
        let notes = NotesContent(
            entries: (0..<60).map { NoteEntry(body: "entry \($0)") }
        )
        let links = LinksContent(
            links: (0..<20).map { LinkEntry(label: "link \($0)", url: "https://example.com/\($0)") }
        )
        let music = MusicContent(
            tracks: (0..<20).map { MusicTrack(url: "https://example.com/track/\($0)") }
        )

        #expect(photos.photos.count == 12)
        #expect(notes.entries.count == 50)
        #expect(links.links.count == 15)
        #expect(music.tracks.count == 10)
    }

    @Test func collectionLimitsAreEnforcedOnDecode() throws {
        let photoJSON = """
        {
          "photos": [
            \((0..<20).map { #"{"localPath":"photo-\#($0).jpg"}"# }.joined(separator: ","))
          ]
        }
        """.data(using: .utf8)!
        let notesJSON = """
        {
          "entries": [
            \((0..<60).map { #"{"body":"entry \#($0)","createdAt":1776800000}"# }.joined(separator: ","))
          ]
        }
        """.data(using: .utf8)!
        let linksJSON = """
        {
          "links": [
            \((0..<20).map { #"{"label":"link \#($0)","url":"https://example.com/\#($0)"}"# }.joined(separator: ","))
          ]
        }
        """.data(using: .utf8)!
        let musicJSON = """
        {
          "tracks": [
            \((0..<20).map { #"{"url":"https://example.com/track/\#($0)"}"# }.joined(separator: ","))
          ]
        }
        """.data(using: .utf8)!

        #expect(try JSONDecoder().decode(PhotoContent.self, from: photoJSON).photos.count == 12)
        #expect(try JSONDecoder().decode(NotesContent.self, from: notesJSON).entries.count == 50)
        #expect(try JSONDecoder().decode(LinksContent.self, from: linksJSON).links.count == 15)
        #expect(try JSONDecoder().decode(MusicContent.self, from: musicJSON).tracks.count == 10)
    }
}

@MainActor
struct StructuredProfileSizingTests {
    @Test func containerHeightSnapsToGridWithoutCrossingBounds() throws {
        #expect(ProfileContainer.normalizedHeight(70) == 80)
        #expect(ProfileContainer.normalizedHeight(81) == 80)
        #expect(ProfileContainer.normalizedHeight(95) == 96)
        #expect(ProfileContainer.normalizedHeight(611) == 600)

        let container = ProfileContainer(kind: .about, height: 95)
        #expect(container.height == 96)
    }
}

@MainActor
struct StructuredProfileMusicTests {
    @Test func musicServiceIsDetectedFromURLHost() throws {
        #expect(MusicTrack(url: "https://open.spotify.com/track/abc").service == .spotify)
        #expect(MusicTrack(url: "https://music.apple.com/us/album/abc").service == .appleMusic)
        #expect(MusicTrack(url: "https://soundcloud.com/artist/track").service == .soundCloud)
        #expect(MusicTrack(url: "https://example.com/music").service == .generic)
    }
}

@MainActor
private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
}
