import Foundation

/// Single-vibe metadata stamped on a published profile so the Explore
/// feed can filter authentically (chips → server query, not chips →
/// nothing-happens). Pinned to a closed set in lockstep with the
/// `profiles_category_check` constraint added by
/// `Supabase/migration_add_profile_category.sql`.
///
/// Stored as the rawValue (snake-or-camel-but-lowercased so the
/// constraint can read it directly without case-folding). Old rows
/// decode as `nil` and the "All" Explore filter passes everything
/// through unchanged.
enum ProfileVibe: String, CaseIterable, Codable, Hashable, Identifiable {
    case anime
    case kpop
    case softDiary
    case myspace
    case writer
    case gamer
    case art
    case music
    case student

    var id: String { rawValue }

    /// Human-facing chip / picker label.
    var label: String {
        switch self {
        case .anime:     return "Anime"
        case .kpop:      return "K-Pop"
        case .softDiary: return "Soft Diary"
        case .myspace:   return "MySpace"
        case .writer:    return "Writer"
        case .gamer:     return "Gamer"
        case .art:       return "Art"
        case .music:     return "Music"
        case .student:   return "Student"
        }
    }

    /// SF Symbol used by chips and the publish picker. Same shapes as
    /// the template picker so the visual vocabulary lines up across
    /// onboarding, publish, and explore.
    var iconSymbol: String {
        switch self {
        case .anime:     return "sparkles.tv"
        case .kpop:      return "music.mic"
        case .softDiary: return "book.pages"
        case .myspace:   return "heart.fill"
        case .writer:    return "text.book.closed"
        case .gamer:     return "gamecontroller.fill"
        case .art:       return "paintpalette"
        case .music:     return "music.note"
        case .student:   return "graduationcap"
        }
    }

    /// Forward-compatible decoder. A future build that adds a new
    /// vibe case shouldn't break decoding on older clients — the
    /// unknown value lands as `nil` (via the optional decode call
    /// sites) and the Explore card still renders.
    init?(rawCategory: String?) {
        guard let rawCategory else { return nil }
        self.init(rawValue: rawCategory)
    }
}
