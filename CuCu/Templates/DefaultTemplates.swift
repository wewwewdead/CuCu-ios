import Foundation

// MARK: - Default templates registry
//
// Seven prebuilt profile designs ported from the HTML/CSS/JS handoff
// bundle (`design-mocks/cucu-templates/templates.jsx`). Each builder
// returns a fully-populated `ProfileDocument` whose nodes match the
// prototype's positioned scene graph.
//
// Coordinate space: the prototype canvas was 320×660 logical units;
// CuCu's page is 390 wide × 1000 tall. Every x / y / w / h / fontSize /
// cornerRadius value coming from the prototype is multiplied by
// `templateScale` (390 / 320 = 1.21875) so layouts scale up cleanly.
//
// Image placeholders use the `bundled:tone-<tone>` URI scheme handled
// by `CanvasImageLoader` — the five gradient SVGs ship inside
// `Assets.xcassets/Tones/`. Users replace them with their own photos
// after applying a template; bundled paths skip the publish-upload
// pipeline so a template that's never had its placeholders swapped
// won't try to upload them.
//
// Seeding is idempotent: each template carries a stable UUID, and
// `TemplateStore.upsertSeededTemplate(...)` either inserts the record
// or refreshes its JSON in place.

/// Stable UUIDs for the seven seeded default templates. Hard-coding
/// UUIDs lets us re-seed on every launch without ever creating
/// duplicates or stranding old IDs in the SwiftData store.
enum DefaultTemplateID {
    static let kawaii      = UUID(uuidString: "CCCC0001-0000-0000-0000-000000000001")!
    static let minimalist  = UUID(uuidString: "CCCC0002-0000-0000-0000-000000000002")!
    static let kpop        = UUID(uuidString: "CCCC0003-0000-0000-0000-000000000003")!
    static let studioIndex = UUID(uuidString: "CCCC0004-0000-0000-0000-000000000004")!
    static let myspace     = UUID(uuidString: "CCCC0005-0000-0000-0000-000000000005")!
    static let coolKid     = UUID(uuidString: "CCCC0006-0000-0000-0000-000000000006")!
    static let artsy       = UUID(uuidString: "CCCC0007-0000-0000-0000-000000000007")!
}

/// One entry in `DefaultTemplates.all`. Uses a closure rather than a
/// pre-built `ProfileDocument` so launch cost is paid only when seeding
/// actually needs to insert / refresh the row.
///
/// `vibe` and `swatch` mirror the prototype's `TPL_*.vibe` / `swatch`
/// fields and feed the picker's card chrome (italic tagline + four
/// little color dots). Built-only data — never persisted to SwiftData,
/// recomputed at picker render time by id lookup.
struct DefaultTemplateSpec {
    let id: UUID
    let name: String
    let vibe: String
    let swatch: [String]
    let build: () -> ProfileDocument
}

enum DefaultTemplates {
    static let all: [DefaultTemplateSpec] = [
        DefaultTemplateSpec(
            id: DefaultTemplateID.kawaii, name: "Kawaii",
            vibe: "kawaii · pastel · sticker collage",
            swatch: ["#FFD9E5", "#FFF1B8", "#D8E9C9", "#B8324B"],
            build: TemplateBuilder.kawaii
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.minimalist, name: "Minimalist",
            vibe: "minimal · editorial · restrained",
            swatch: ["#FBF8F2", "#1A1A1A", "#7A7A7A", "#E8E4D8"],
            build: TemplateBuilder.minimalist
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.kpop, name: "Kpop",
            vibe: "k-pop · photocard · deluxe edition",
            swatch: ["#FFE7EE", "#FF3D7A", "#1A0E1F", "#FFD93D"],
            build: TemplateBuilder.kpop
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.studioIndex, name: "Studio Index",
            vibe: "portfolio · case-study · clean",
            swatch: ["#F2EEE3", "#1F2D45", "#D2A85A", "#FFFFFF"],
            build: TemplateBuilder.studioIndex
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.myspace, name: "Myspace",
            vibe: "myspace · y2k · about-me chaos",
            swatch: ["#1B1B66", "#FF66CC", "#39E6F0", "#FFD93D"],
            build: TemplateBuilder.myspace
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.coolKid, name: "Cool Kid",
            vibe: "cool kid · streetwear · stencil",
            swatch: ["#1F2018", "#FF5A1F", "#E8E2D0", "#9DA180"],
            build: TemplateBuilder.coolKid
        ),
        DefaultTemplateSpec(
            id: DefaultTemplateID.artsy, name: "Artsy",
            vibe: "artsy · cutesy · paper collage",
            swatch: ["#F4ECDA", "#C44536", "#3F4A3A", "#E8C28E"],
            build: TemplateBuilder.artsy
        ),
    ]

    /// O(1) lookup so the picker can pull vibe / swatch metadata for a
    /// `ProfileTemplate` row by its stable seed UUID. Returns `nil` for
    /// user-saved templates that aren't in the seeded set — the picker
    /// falls back to a plain card layout for those.
    static func spec(for id: UUID) -> DefaultTemplateSpec? {
        all.first(where: { $0.id == id })
    }
}
