import Foundation
import SwiftUI

/// Discriminator for the polymorphic ProfileBlock JSON. Adding a future block
/// type means extending this enum and the ProfileBlock switch in
/// init(from:)/encode(to:).
enum ProfileBlockType: String, Codable, Hashable {
    case text
    case image
    case container
}

/// System-safe font families. We deliberately avoid bundled fonts so the same
/// JSON renders identically without a font asset round-trip.
enum ProfileFontName: String, Codable, Hashable, CaseIterable {
    case system = "System"
    case serif = "Serif"
    case rounded = "Rounded"
    case monospaced = "Monospaced"

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
}

enum ProfileTextAlignment: String, Codable, Hashable, CaseIterable {
    case leading, center, trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// How a block sizes itself horizontally inside the page.
///
/// - `fill`: take the full content width
/// - `compact`: hug content; positioned by the block's alignment
/// - `centered`: hug content; always centered horizontally
enum BlockWidthStyle: String, Codable, Hashable, CaseIterable {
    case fill
    case compact
    case centered
}

// MARK: - Text block

struct TextBlockData: Codable, Identifiable, Hashable {
    var id: UUID
    var content: String
    var fontName: ProfileFontName
    var fontSize: Double
    var textColorHex: String
    var backgroundColorHex: String
    var cornerRadius: Double
    var padding: Double
    var alignment: ProfileTextAlignment
    var widthStyle: BlockWidthStyle = .fill

    static func placeholder(theme: ProfileTheme) -> TextBlockData {
        TextBlockData(
            id: UUID(),
            content: "Tap to edit your text",
            fontName: theme.defaultFontName,
            fontSize: 17,
            textColorHex: theme.defaultTextColorHex,
            backgroundColorHex: "#FFFFFF00",
            cornerRadius: 12,
            padding: 16,
            alignment: .leading,
            widthStyle: .fill
        )
    }
}

extension TextBlockData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.content = try c.decode(String.self, forKey: .content)
        self.fontName = try c.decode(ProfileFontName.self, forKey: .fontName)
        self.fontSize = try c.decode(Double.self, forKey: .fontSize)
        self.textColorHex = try c.decode(String.self, forKey: .textColorHex)
        self.backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        self.cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        self.padding = try c.decode(Double.self, forKey: .padding)
        self.alignment = try c.decode(ProfileTextAlignment.self, forKey: .alignment)
        self.widthStyle = try c.decodeIfPresent(BlockWidthStyle.self, forKey: .widthStyle) ?? .fill
    }
}

// MARK: - Image block

/// How an image fills its layout frame.
enum ImageFit: String, Codable, Hashable, CaseIterable {
    case fill
    case fit

    var contentMode: ContentMode {
        switch self {
        case .fill: return .fill
        case .fit: return .fit
        }
    }
}

/// Aspect ratio constraint for the image's layout frame.
///
/// `auto` lets the image use its intrinsic ratio; the others clip into a
/// fixed-shape frame so collages of mixed-aspect images look consistent.
enum ImageAspectRatio: String, Codable, Hashable, CaseIterable {
    case auto
    case square
    case portrait
    case landscape

    /// width / height. Unused for `.auto`.
    var numericRatio: Double {
        switch self {
        case .auto: return 1.0
        case .square: return 1.0
        case .portrait: return 3.0 / 4.0
        case .landscape: return 4.0 / 3.0
        }
    }
}

struct ImageBlockData: Codable, Identifiable, Hashable {
    var id: UUID
    /// Path relative to LocalAssetStore.rootURL. Empty if no image is attached.
    var localImagePath: String
    /// Optional caption / accessibility label.
    var caption: String
    var cornerRadius: Double
    var padding: Double
    var backgroundColorHex: String
    var imageFit: ImageFit
    var aspectRatio: ImageAspectRatio
    var widthStyle: BlockWidthStyle

    static func newBlock(id: UUID = UUID(), localImagePath: String) -> ImageBlockData {
        ImageBlockData(
            id: id,
            localImagePath: localImagePath,
            caption: "",
            cornerRadius: 12,
            padding: 0,
            backgroundColorHex: "#FFFFFF00",
            imageFit: .fill,
            aspectRatio: .auto,
            widthStyle: .fill
        )
    }
}

// MARK: - Container block

/// Stack axis for a container's children.
enum ContainerAxis: String, Codable, Hashable, CaseIterable {
    case vertical
    case horizontal
}

/// Cross-axis alignment of a container's children.
///
/// Semantics:
/// - For `.vertical` axis: leading = left, center = horizontally centered, trailing = right.
/// - For `.horizontal` axis: leading = top, center = vertically centered, trailing = bottom.
enum ContainerContentAlignment: String, Codable, Hashable, CaseIterable {
    case leading
    case center
    case trailing

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var vertical: VerticalAlignment {
        switch self {
        case .leading: return .top
        case .center: return .center
        case .trailing: return .bottom
        }
    }
}

/// Outer clip shape applied to a container's contents + background. `.circle`
/// is the easy path to circular avatars (drop an image inside a circle-clipped
/// container with padding 0).
enum ContainerClipShape: String, Codable, Hashable, CaseIterable {
    case rectangle
    case circle
}

/// A container holds other blocks (including other containers) and is the
/// architectural primitive that lets a profile be composed like a page
/// designer rather than a flat list. The schema is recursive — `children` is
/// `[ProfileBlock]`, which can itself contain `.container(...)`.
struct ContainerBlockData: Codable, Identifiable, Hashable {
    var id: UUID
    var children: [ProfileBlock]
    var axis: ContainerAxis
    var spacing: Double
    var contentAlignment: ContainerContentAlignment
    var padding: Double
    var cornerRadius: Double
    var backgroundColorHex: String
    var widthStyle: BlockWidthStyle
    var clipShape: ContainerClipShape

    static func newContainer(id: UUID = UUID()) -> ContainerBlockData {
        ContainerBlockData(
            id: id,
            children: [],
            axis: .vertical,
            spacing: 12,
            contentAlignment: .leading,
            padding: 16,
            cornerRadius: 16,
            backgroundColorHex: "#FFFFFF00",
            widthStyle: .fill,
            clipShape: .rectangle
        )
    }
}

extension ContainerBlockData {
    /// Defensive decoder — every field except `id` falls back to a sensible
    /// default so future schema additions don't break older drafts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.children = try c.decodeIfPresent([ProfileBlock].self, forKey: .children) ?? []
        self.axis = try c.decodeIfPresent(ContainerAxis.self, forKey: .axis) ?? .vertical
        self.spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 12
        self.contentAlignment = try c.decodeIfPresent(ContainerContentAlignment.self, forKey: .contentAlignment) ?? .leading
        self.padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 16
        self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 16
        self.backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#FFFFFF00"
        self.widthStyle = try c.decodeIfPresent(BlockWidthStyle.self, forKey: .widthStyle) ?? .fill
        self.clipShape = try c.decodeIfPresent(ContainerClipShape.self, forKey: .clipShape) ?? .rectangle
    }
}

// MARK: - Polymorphic block

/// Polymorphic block. Encoded as a flat JSON object with a `type` discriminator
/// so a future web renderer can read the same schema without nested unwrapping.
enum ProfileBlock: Identifiable, Hashable {
    case text(TextBlockData)
    case image(ImageBlockData)
    case container(ContainerBlockData)

    var id: UUID {
        switch self {
        case .text(let data): return data.id
        case .image(let data): return data.id
        case .container(let data): return data.id
        }
    }

    var type: ProfileBlockType {
        switch self {
        case .text: return .text
        case .image: return .image
        case .container: return .container
        }
    }
}

extension ProfileBlock: Codable {
    private enum DiscriminatorKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try container.decode(ProfileBlockType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try TextBlockData(from: decoder))
        case .image:
            self = .image(try ImageBlockData(from: decoder))
        case .container:
            self = .container(try ContainerBlockData(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DiscriminatorKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .text(let data):
            try data.encode(to: encoder)
        case .image(let data):
            try data.encode(to: encoder)
        case .container(let data):
            try data.encode(to: encoder)
        }
    }
}

// MARK: - Recursive helpers

extension ProfileBlock {
    /// All `ImageBlockData` reachable from this block, including those nested
    /// inside containers (depth-first). Used by the publish flow to upload
    /// every image regardless of nesting depth.
    var imageBlocksDeep: [ImageBlockData] {
        switch self {
        case .text:
            return []
        case .image(let data):
            return [data]
        case .container(let data):
            return data.children.flatMap { $0.imageBlocksDeep }
        }
    }
}

extension Array where Element == ProfileBlock {
    var imageBlocksDeep: [ImageBlockData] {
        flatMap { $0.imageBlocksDeep }
    }
}
