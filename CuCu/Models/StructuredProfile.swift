import Foundation

struct StructuredProfile: Codable, Hashable {
    static let schemaVersion = 2
    static let defaultPageBackgroundHex = "#F8F6F2"

    var id: UUID
    var schemaVersion: Int
    var header: ProfileHeader
    var containers: [ProfileContainer]
    var themeKey: String?
    var pageBackgroundHex: String
    var pageBackgroundPatternKey: String?
    var pageBackgroundImagePath: String?
    var pageBackgroundBlur: Double?
    var pageBackgroundVignette: Double?
    var pageBackgroundImageOpacity: Double?

    init(id: UUID = UUID(),
         schemaVersion: Int = StructuredProfile.schemaVersion,
         header: ProfileHeader = ProfileHeader(),
         containers: [ProfileContainer] = [],
         themeKey: String? = nil,
         pageBackgroundHex: String = StructuredProfile.defaultPageBackgroundHex,
         pageBackgroundPatternKey: String? = nil,
         pageBackgroundImagePath: String? = nil,
         pageBackgroundBlur: Double? = nil,
         pageBackgroundVignette: Double? = nil,
         pageBackgroundImageOpacity: Double? = nil) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.header = header
        self.containers = containers
        self.themeKey = themeKey
        self.pageBackgroundHex = pageBackgroundHex
        self.pageBackgroundPatternKey = pageBackgroundPatternKey
        self.pageBackgroundImagePath = pageBackgroundImagePath
        self.pageBackgroundBlur = pageBackgroundBlur
        self.pageBackgroundVignette = pageBackgroundVignette
        self.pageBackgroundImageOpacity = pageBackgroundImageOpacity
    }
}

extension StructuredProfile {
    static var seeded: StructuredProfile {
        StructuredProfile(
            header: ProfileHeader(fullName: "", status: "", profilePhotoPath: nil),
            containers: [
                ProfileContainer(
                    kind: .about,
                    variantKey: "about.minimal",
                    height: 168,
                    content: .about(AboutContent(title: "About Me", body: ""))
                ),
                ProfileContainer(
                    kind: .favorites,
                    variantKey: "favorites.list",
                    height: 216,
                    content: .favorites(FavoritesContent(title: "Favorites", items: []))
                ),
                ProfileContainer(
                    kind: .photo,
                    variantKey: "photo.grid",
                    height: 288,
                    content: .photo(PhotoContent(title: nil, photos: []))
                ),
                ProfileContainer(
                    kind: .links,
                    variantKey: "links.pill",
                    height: 168,
                    content: .links(LinksContent(title: "Links", links: []))
                ),
                ProfileContainer(
                    kind: .notes,
                    variantKey: "notes.timeline",
                    height: 216,
                    content: .notes(NotesContent(title: "Notes", entries: []))
                )
            ]
        )
    }
}

struct ProfileHeader: Codable, Hashable {
    static let maxFullNameLength = 60
    static let maxStatusLength = 140

    var fullName: String {
        didSet { fullName = Self.clamped(fullName, maxLength: Self.maxFullNameLength) }
    }
    var status: String {
        didSet { status = Self.clamped(status, maxLength: Self.maxStatusLength) }
    }
    var profilePhotoPath: String?

    init(fullName: String = "", status: String = "", profilePhotoPath: String? = nil) {
        self.fullName = Self.clamped(fullName, maxLength: Self.maxFullNameLength)
        self.status = Self.clamped(status, maxLength: Self.maxStatusLength)
        self.profilePhotoPath = profilePhotoPath
    }

    private enum CodingKeys: String, CodingKey {
        case fullName
        case status
        case profilePhotoPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fullName: try c.decodeIfPresent(String.self, forKey: .fullName) ?? "",
            status: try c.decodeIfPresent(String.self, forKey: .status) ?? "",
            profilePhotoPath: try c.decodeIfPresent(String.self, forKey: .profilePhotoPath)
        )
    }

    private static func clamped(_ value: String, maxLength: Int) -> String {
        String(value.prefix(maxLength))
    }
}

struct ProfileContainer: Codable, Hashable, Identifiable {
    static let minHeight: Double = 80
    static let maxHeight: Double = 600
    static let heightGrid: Double = 24

    var id: UUID
    var kind: ContainerKind {
        didSet {
            variantKey = ContainerVariantRegistry.normalizedVariantKey(variantKey, for: kind)
            content = content.normalized(for: kind)
        }
    }
    var variantKey: String {
        didSet { variantKey = ContainerVariantRegistry.normalizedVariantKey(variantKey, for: kind) }
    }
    var height: Double {
        didSet { height = Self.normalizedHeight(height) }
    }
    var content: ContainerContent {
        didSet { content = content.normalized(for: kind) }
    }

    init(id: UUID = UUID(),
         kind: ContainerKind,
         variantKey: String? = nil,
         height: Double = 216,
         content: ContainerContent? = nil) {
        self.id = id
        self.kind = kind
        self.variantKey = ContainerVariantRegistry.normalizedVariantKey(
            variantKey ?? ContainerVariantRegistry.defaultVariantKey(for: kind),
            for: kind
        )
        self.height = Self.normalizedHeight(height)
        self.content = (content ?? .empty(for: kind)).normalized(for: kind)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case variantKey
        case height
        case content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ContainerKind.about.rawValue
        let height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 216

        guard let kind = ContainerKind(rawValue: rawKind) else {
            self.init(id: id, kind: .about, height: height, content: .empty(for: .about))
            return
        }

        let content: ContainerContent
        if c.contains(.content) {
            content = try ContainerContent.decode(from: c.superDecoder(forKey: .content), kind: kind)
        } else {
            content = .empty(for: kind)
        }

        self.init(
            id: id,
            kind: kind,
            variantKey: try c.decodeIfPresent(String.self, forKey: .variantKey),
            height: height,
            content: content
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(ContainerVariantRegistry.normalizedVariantKey(variantKey, for: kind), forKey: .variantKey)
        try c.encode(Self.normalizedHeight(height), forKey: .height)
        try content.normalized(for: kind).encode(to: c.superEncoder(forKey: .content))
    }

    static func normalizedHeight(_ value: Double) -> Double {
        let snapped = (value / heightGrid).rounded() * heightGrid
        return min(maxHeight, max(minHeight, snapped))
    }
}

enum ContainerKind: String, Codable, CaseIterable {
    case about
    case favorites
    case notes
    case photo
    case links
    case music
}

enum ContainerVariantRegistry {
    static let keysByKind: [ContainerKind: [String]] = [
        .about: ["about.minimal", "about.card"],
        .favorites: ["favorites.list", "favorites.grid"],
        .notes: ["notes.timeline", "notes.cards"],
        .photo: ["photo.grid", "photo.stack"],
        .links: ["links.pill", "links.list"],
        .music: ["music.list", "music.cards"]
    ]

    static func keys(for kind: ContainerKind) -> [String] {
        keysByKind[kind] ?? []
    }

    static func defaultVariantKey(for kind: ContainerKind) -> String {
        keys(for: kind).first ?? "\(kind.rawValue).default"
    }

    static func normalizedVariantKey(_ key: String, for kind: ContainerKind) -> String {
        keys(for: kind).contains(key) ? key : defaultVariantKey(for: kind)
    }
}

enum ContainerContent: Codable, Hashable {
    case about(AboutContent)
    case favorites(FavoritesContent)
    case notes(NotesContent)
    case photo(PhotoContent)
    case links(LinksContent)
    case music(MusicContent)
}

extension ContainerContent {
    static func empty(for kind: ContainerKind) -> ContainerContent {
        switch kind {
        case .about:
            return .about(AboutContent(title: "About Me", body: ""))
        case .favorites:
            return .favorites(FavoritesContent(title: "Favorites", items: []))
        case .notes:
            return .notes(NotesContent(title: "Notes", entries: []))
        case .photo:
            return .photo(PhotoContent(title: nil, photos: []))
        case .links:
            return .links(LinksContent(title: "Links", links: []))
        case .music:
            return .music(MusicContent(title: "Music", tracks: []))
        }
    }

    var kind: ContainerKind {
        switch self {
        case .about: return .about
        case .favorites: return .favorites
        case .notes: return .notes
        case .photo: return .photo
        case .links: return .links
        case .music: return .music
        }
    }

    var isEmpty: Bool {
        switch self {
        case .about(let content):
            return content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .favorites(let content):
            return content.items.isEmpty
        case .notes(let content):
            return content.entries.isEmpty
        case .photo(let content):
            return content.photos.isEmpty
        case .links(let content):
            return content.links.isEmpty
        case .music(let content):
            return content.tracks.isEmpty
        }
    }

    func normalized(for kind: ContainerKind) -> ContainerContent {
        self.kind == kind ? self : .empty(for: kind)
    }

    static func decode(from decoder: Decoder, kind: ContainerKind) throws -> ContainerContent {
        switch kind {
        case .about:
            return .about(try AboutContent(from: decoder))
        case .favorites:
            return .favorites(try FavoritesContent(from: decoder))
        case .notes:
            return .notes(try NotesContent(from: decoder))
        case .photo:
            return .photo(try PhotoContent(from: decoder))
        case .links:
            return .links(try LinksContent(from: decoder))
        case .music:
            return .music(try MusicContent(from: decoder))
        }
    }

    init(from decoder: Decoder) throws {
        self = .about(try AboutContent(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .about(let content):
            try content.encode(to: encoder)
        case .favorites(let content):
            try content.encode(to: encoder)
        case .notes(let content):
            try content.encode(to: encoder)
        case .photo(let content):
            try content.encode(to: encoder)
        case .links(let content):
            try content.encode(to: encoder)
        case .music(let content):
            try content.encode(to: encoder)
        }
    }
}

struct AboutContent: Codable, Hashable {
    static let maxBodyLength = 500

    var title: String
    var body: String {
        didSet { body = String(body.prefix(Self.maxBodyLength)) }
    }

    init(title: String = "About Me", body: String = "") {
        self.title = title
        self.body = String(body.prefix(Self.maxBodyLength))
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "About Me",
            body: try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        )
    }
}

struct FavoritesContent: Codable, Hashable {
    static let maxItems = 20
    static let maxItemLength = 80

    var title: String
    var items: [String] {
        didSet { items = Self.normalizedItems(items) }
    }

    init(title: String = "Favorites", items: [String] = []) {
        self.title = title
        self.items = Self.normalizedItems(items)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Favorites",
            items: try c.decodeIfPresent([String].self, forKey: .items) ?? []
        )
    }

    private static func normalizedItems(_ items: [String]) -> [String] {
        items.prefix(maxItems).map { String($0.prefix(maxItemLength)) }
    }
}

struct NotesContent: Codable, Hashable {
    static let maxEntries = 50

    var title: String
    var entries: [NoteEntry] {
        didSet { entries = Array(entries.prefix(Self.maxEntries)) }
    }

    init(title: String = "Notes", entries: [NoteEntry] = []) {
        self.title = title
        self.entries = Array(entries.prefix(Self.maxEntries))
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Notes",
            entries: try c.decodeIfPresent([NoteEntry].self, forKey: .entries) ?? []
        )
    }
}

struct NoteEntry: Codable, Hashable, Identifiable {
    static let maxBodyLength = 280

    var id: UUID
    var body: String {
        didSet { body = String(body.prefix(Self.maxBodyLength)) }
    }
    var createdAt: Date

    init(id: UUID = UUID(), body: String = "", createdAt: Date = .now) {
        self.id = id
        self.body = String(body.prefix(Self.maxBodyLength))
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case body
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            body: try c.decodeIfPresent(String.self, forKey: .body) ?? "",
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        )
    }
}

struct PhotoContent: Codable, Hashable {
    static let maxPhotos = 12

    var title: String?
    var photos: [PhotoEntry] {
        didSet { photos = Array(photos.prefix(Self.maxPhotos)) }
    }

    init(title: String? = nil, photos: [PhotoEntry] = []) {
        self.title = title
        self.photos = Array(photos.prefix(Self.maxPhotos))
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case photos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title),
            photos: try c.decodeIfPresent([PhotoEntry].self, forKey: .photos) ?? []
        )
    }
}

struct PhotoEntry: Codable, Hashable, Identifiable {
    static let maxCaptionLength = 60

    var id: UUID
    var localPath: String?
    var remoteURL: String?
    var caption: String? {
        didSet {
            if let caption {
                self.caption = String(caption.prefix(Self.maxCaptionLength))
            }
        }
    }

    init(id: UUID = UUID(),
         localPath: String? = nil,
         remoteURL: String? = nil,
         caption: String? = nil) {
        self.id = id
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.caption = caption.map { String($0.prefix(Self.maxCaptionLength)) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case localPath
        case remoteURL
        case caption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            localPath: try c.decodeIfPresent(String.self, forKey: .localPath),
            remoteURL: try c.decodeIfPresent(String.self, forKey: .remoteURL),
            caption: try c.decodeIfPresent(String.self, forKey: .caption)
        )
    }
}

struct LinksContent: Codable, Hashable {
    static let maxLinks = 15

    var title: String
    var links: [LinkEntry] {
        didSet { links = Array(links.prefix(Self.maxLinks)) }
    }

    init(title: String = "Links", links: [LinkEntry] = []) {
        self.title = title
        self.links = Array(links.prefix(Self.maxLinks))
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case links
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Links",
            links: try c.decodeIfPresent([LinkEntry].self, forKey: .links) ?? []
        )
    }
}

struct LinkEntry: Codable, Hashable, Identifiable {
    static let maxLabelLength = 40

    var id: UUID
    var label: String {
        didSet { label = String(label.prefix(Self.maxLabelLength)) }
    }
    var url: String

    init(id: UUID = UUID(), label: String = "", url: String = "") {
        self.id = id
        self.label = String(label.prefix(Self.maxLabelLength))
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        )
    }

    var hasHTTPURL: Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

struct MusicContent: Codable, Hashable {
    static let maxTracks = 10

    var title: String
    var tracks: [MusicTrack] {
        didSet { tracks = Array(tracks.prefix(Self.maxTracks)) }
    }

    init(title: String = "Music", tracks: [MusicTrack] = []) {
        self.title = title
        self.tracks = Array(tracks.prefix(Self.maxTracks))
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Music",
            tracks: try c.decodeIfPresent([MusicTrack].self, forKey: .tracks) ?? []
        )
    }
}

struct MusicTrack: Codable, Hashable, Identifiable {
    var id: UUID
    var url: String
    var label: String?
    var artworkURL: String?

    init(id: UUID = UUID(), url: String = "", label: String? = nil, artworkURL: String? = nil) {
        self.id = id
        self.url = url
        self.label = label
        self.artworkURL = artworkURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case label
        case artworkURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
            label: try c.decodeIfPresent(String.self, forKey: .label),
            artworkURL: try c.decodeIfPresent(String.self, forKey: .artworkURL)
        )
    }
}

enum MusicService: String, Codable, Hashable {
    case spotify
    case appleMusic
    case soundCloud
    case generic
}

extension MusicTrack {
    var service: MusicService {
        guard let host = URLComponents(string: url)?.host?.lowercased() else {
            return .generic
        }
        if host == "spotify.com" || host.hasSuffix(".spotify.com") {
            return .spotify
        }
        if host == "music.apple.com" || host.hasSuffix(".music.apple.com") {
            return .appleMusic
        }
        if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") {
            return .soundCloud
        }
        return .generic
    }
}
