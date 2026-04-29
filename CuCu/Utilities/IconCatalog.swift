import Foundation

/// Curated SF Symbol catalog for `.icon` and `.link` nodes. Built from
/// what the major social profile pages (Instagram, TikTok, Twitter/X,
/// Facebook, YouTube, LinkedIn, Pinterest, Snapchat) actually use, plus
/// a decorative starter set tuned to the cute / scrapbook aesthetic
/// CuCu leans into.
///
/// Symbols are addressed by their SF Symbol name, which is what
/// `UIImage(systemName:)` expects. A symbol that fails to resolve on
/// the runtime SF Symbols version (e.g. running on an older OS than
/// the one the symbol shipped in) renders as a placeholder via the
/// caller's existing fallback, so the picker is always safe.
///
/// The list is **flat** but grouped via comment markers so a future
/// "categorized picker" upgrade can read sections without changing
/// the data shape. Order inside each section is muscle-memory order
/// for the picker (most-used first).
enum IconCatalog {
    /// Ordered starter pack — every icon shown in the picker.
    static let starter: [String] = [
        // ── Hearts & love ─────────────────────────────────────────
        "heart.fill",
        "heart",
        "heart.text.square.fill",

        // ── Stars, sparkle, magic ─────────────────────────────────
        "star.fill",
        "star",
        "sparkle",
        "sparkles",
        "wand.and.stars",
        "rosette",

        // ── Cute decorative props ─────────────────────────────────
        "crown.fill",
        "diamond.fill",
        "ribbon",
        "gift.fill",
        "balloon.fill",
        "circle.hexagongrid.fill",
        "lightbulb.fill",
        "infinity",

        // ── Nature & mood ────────────────────────────────────────
        "moon.fill",
        "moon.zzz.fill",
        "sun.max.fill",
        "cloud.fill",
        "flame.fill",
        "bolt.fill",
        "drop.fill",
        "leaf.fill",
        "camera.macro",            // tiny flower glyph
        "pawprint.fill",

        // ── Music & audio ────────────────────────────────────────
        "music.note",
        "music.note.list",
        "headphones",
        "mic.fill",
        "speaker.wave.2.fill",
        "waveform",

        // ── Camera, photo, video ─────────────────────────────────
        "camera.fill",
        "video.fill",
        "play.circle.fill",
        "photo.fill",
        "photo.on.rectangle",

        // ── Communication ────────────────────────────────────────
        "envelope.fill",
        "paperplane.fill",
        "message.fill",
        "bubble.left.fill",
        "bubble.right.fill",
        "phone.fill",
        "quote.bubble.fill",

        // ── Social actions (the heart of every profile page) ─────
        "hand.thumbsup.fill",                  // like / endorse
        "arrow.2.squarepath",                  // repost / retweet
        "arrowshape.turn.up.right.fill",       // forward / share
        "square.and.arrow.up",                 // iOS share sheet
        "bookmark.fill",                       // save
        "bell.fill",                           // notifications
        "bell.badge.fill",                     // unread notifications
        "eye.fill",                            // views
        "magnifyingglass",                     // search

        // ── People & profile ─────────────────────────────────────
        "person.fill",
        "person.crop.circle.fill",
        "person.2.fill",
        "person.3.fill",
        "person.badge.plus",                   // add friend / follow
        "checkmark.seal.fill",                 // verified badge

        // ── Settings & menu (the "..." family) ───────────────────
        "ellipsis",                            // bare three dots
        "ellipsis.circle.fill",                // three dots in a circle
        "gearshape.fill",                      // settings cog
        "line.3.horizontal",                   // hamburger menu
        "slider.horizontal.3",                 // filters / adjust

        // ── Tags & references ────────────────────────────────────
        "tag.fill",
        "number",                              // # hashtag
        "at",                                  // @ mention
        "pin.fill",                            // pinned post

        // ── Time & places ────────────────────────────────────────
        "calendar",
        "clock.fill",
        "house.fill",
        "globe",
        "link",
        "location.fill",
        "mappin.circle.fill",

        // ── Shop & premium ───────────────────────────────────────
        "bag.fill",
        "cart.fill",
        "creditcard.fill",
        "dollarsign.circle.fill",

        // ── Privacy & status ─────────────────────────────────────
        "lock.fill",
        "circle.fill",                         // online dot

        // ── Editing & creating ───────────────────────────────────
        "pencil",
        "square.and.pencil",
        "paintbrush.fill",
        "paintpalette.fill",

        // ── Faces & vibes ────────────────────────────────────────
        "smiley.fill",
        "face.smiling.inverse",
        "eyes",
        "hand.wave.fill",

        // ── Social brands ────────────────────────────────────────
        // `brand.*` names resolve to vendored simple-icons SVGs under
        // Assets.xcassets/SocialIcons/. `IconNodeView` recognises the
        // prefix and loads them as template images instead of going
        // through `UIImage(systemName:)`.
        "brand.instagram",
        "brand.tiktok",
        "brand.x",
        "brand.threads",
        "brand.facebook",
        "brand.youtube",
        "brand.linkedin",
        "brand.pinterest",
        "brand.snapchat",
        "brand.whatsapp",
        "brand.discord",
        "brand.twitch",
        "brand.spotify",
        "brand.github",

        // ── Multi-color glyphs ───────────────────────────────────
        // `multi.*` names resolve to vendored multi-color SVGs under
        // Assets.xcassets/Glyphs/. `IconNodeView` loads them with
        // `.alwaysOriginal` so the SVG's own fills paint regardless
        // of the user's tintColor pick.
        "multi.tlights",
    ]

    /// Friendly title for the menu / grid. Falls back to a humanised
    /// form of the SF Symbol name if the curated map doesn't list it
    /// — a brand-new symbol ships with a sensible auto-label even
    /// before the entry is added below.
    static func label(for symbol: String) -> String {
        let labels: [String: String] = [
            // hearts & love
            "heart.fill":                   "Heart",
            "heart":                        "Heart Outline",
            "heart.text.square.fill":       "Note",

            // stars / sparkle
            "star.fill":                    "Star",
            "star":                         "Star Outline",
            "sparkle":                      "Sparkle",
            "sparkles":                     "Sparkles",
            "wand.and.stars":               "Magic",
            "rosette":                      "Award",

            // cute decorative
            "crown.fill":                   "Crown",
            "diamond.fill":                 "Diamond",
            "ribbon":                       "Bow",
            "gift.fill":                    "Gift",
            "balloon.fill":                 "Balloon",
            "circle.hexagongrid.fill":      "Honeycomb",
            "lightbulb.fill":               "Idea",
            "infinity":                     "Infinity",

            // nature & mood
            "moon.fill":                    "Moon",
            "moon.zzz.fill":                "Sleep",
            "sun.max.fill":                 "Sun",
            "cloud.fill":                   "Cloud",
            "flame.fill":                   "Flame",
            "bolt.fill":                    "Bolt",
            "drop.fill":                    "Drop",
            "leaf.fill":                    "Leaf",
            "camera.macro":                 "Flower",
            "pawprint.fill":                "Paw",

            // music & audio
            "music.note":                   "Music Note",
            "music.note.list":              "Playlist",
            "headphones":                   "Headphones",
            "mic.fill":                     "Mic",
            "speaker.wave.2.fill":          "Speaker",
            "waveform":                     "Audio Wave",

            // camera / photo / video
            "camera.fill":                  "Camera",
            "video.fill":                   "Video",
            "play.circle.fill":             "Play",
            "photo.fill":                   "Photo",
            "photo.on.rectangle":           "Gallery",

            // communication
            "envelope.fill":                "Mail",
            "paperplane.fill":              "Send",
            "message.fill":                 "Message",
            "bubble.left.fill":             "Bubble Left",
            "bubble.right.fill":            "Bubble Right",
            "phone.fill":                   "Phone",
            "quote.bubble.fill":            "Quote",

            // social actions
            "hand.thumbsup.fill":           "Thumbs Up",
            "arrow.2.squarepath":           "Repost",
            "arrowshape.turn.up.right.fill":"Forward",
            "square.and.arrow.up":          "Share",
            "bookmark.fill":                "Bookmark",
            "bell.fill":                    "Bell",
            "bell.badge.fill":              "Notify",
            "eye.fill":                     "Views",
            "magnifyingglass":              "Search",

            // people & profile
            "person.fill":                  "Person",
            "person.crop.circle.fill":      "Profile",
            "person.2.fill":                "Friends",
            "person.3.fill":                "Group",
            "person.badge.plus":            "Add Friend",
            "checkmark.seal.fill":          "Verified",

            // settings & menu
            "ellipsis":                     "More",
            "ellipsis.circle.fill":         "More Menu",
            "gearshape.fill":               "Settings",
            "line.3.horizontal":            "Menu",
            "slider.horizontal.3":          "Filters",

            // tags & references
            "tag.fill":                     "Tag",
            "number":                       "Hashtag",
            "at":                           "Mention",
            "pin.fill":                     "Pinned",

            // time & places
            "calendar":                     "Calendar",
            "clock.fill":                   "Clock",
            "house.fill":                   "Home",
            "globe":                        "Globe",
            "link":                         "Link",
            "location.fill":                "Location",
            "mappin.circle.fill":           "Map Pin",

            // shop & premium
            "bag.fill":                     "Bag",
            "cart.fill":                    "Cart",
            "creditcard.fill":              "Payment",
            "dollarsign.circle.fill":       "Money",

            // privacy & status
            "lock.fill":                    "Lock",
            "circle.fill":                  "Dot",

            // editing
            "pencil":                       "Pencil",
            "square.and.pencil":            "Edit",
            "paintbrush.fill":              "Brush",
            "paintpalette.fill":            "Palette",

            // faces & vibes
            "smiley.fill":                  "Smiley",
            "face.smiling.inverse":         "Face",
            "eyes":                         "Eyes",
            "hand.wave.fill":               "Wave",

            // social brands
            "brand.instagram":              "Instagram",
            "brand.tiktok":                 "TikTok",
            "brand.x":                      "X",
            "brand.threads":                "Threads",
            "brand.facebook":               "Facebook",
            "brand.youtube":                "YouTube",
            "brand.linkedin":               "LinkedIn",
            "brand.pinterest":              "Pinterest",
            "brand.snapchat":               "Snapchat",
            "brand.whatsapp":               "WhatsApp",
            "brand.discord":                "Discord",
            "brand.twitch":                 "Twitch",
            "brand.spotify":                "Spotify",
            "brand.github":                 "GitHub",

            // multi-color glyphs
            "multi.tlights":                "Traffic Lights",
        ]
        if let humanised = labels[symbol] { return humanised }
        // Fallback: turn "music.note" → "Music Note", "star.fill" → "Star Fill"
        return symbol
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
