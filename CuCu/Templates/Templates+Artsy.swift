import Foundation

// Template 7 — Artsy (paper-collage gallerist)
//
// Cutesy/artsy. Warm linen background, hand-cut paper feel, mixed
// fonts (Caveat handwriting + Fraunces serif), torn-paper containers,
// soft muted palette. Tilted polaroid avatar with caption underneath,
// ivory note panel, tape-label links. Source: TPL_ARTSY.

extension TemplateBuilder {
    static func artsy() -> ProfileDocument {
        let masthead     = UUID()
        let mastR        = UUID()
        let header       = UUID()
        let subtitle     = UUID()
        let polaroid     = UUID()
        let avatar       = UUID()
        let polaroidCap  = UUID()
        let heart        = UUID()
        let div1         = UUID()
        let notePanel    = UUID()
        let noteLabel    = UUID()
        let note         = UUID()
        let worksLabel   = UUID()
        let worksCount   = UUID()
        let gallery      = UUID()
        let link1        = UUID()
        let link2        = UUID()
        let link3        = UUID()
        let sig          = UUID()

        return assemble(
            bgColor: "#F4ECDA",
            bgPatternKey: "dots",
            orderedNodes: [
                textNode(masthead, x: 24, y: 30, w: 272, h: 14,
                         text: "— SKETCHBOOK · NO. 12",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#3F4A3A", align: .leading),
                textNode(mastR, x: 96, y: 30, w: 200, h: 14,
                         text: "spring · 26",
                         font: .fraunces, weight: .medium, size: 10,
                         color: "#3F4A3A", align: .trailing),

                textNode(header, x: 24, y: 56, w: 272, h: 56,
                         text: "wren\nfields.",
                         font: .fraunces, weight: .bold, size: 38,
                         color: "#3F4A3A", align: .leading),

                textNode(subtitle, x: 24, y: 152, w: 200, h: 26,
                         text: "painter, tiny things, mostly yellow.",
                         font: .caveat, weight: .bold, size: 18,
                         color: "#C44536", align: .leading),

                containerNode(polaroid, x: 196, y: 78, w: 100, h: 116,
                              bg: "#FFFFFF", radius: 4, borderW: 1, borderC: "#3F4A3A"),
                imageNode(avatar, x: 202, y: 84, w: 88, h: 88,
                          tone: "butter", radius: 2, clip: .rectangle),
                textNode(polaroidCap, x: 196, y: 174, w: 100, h: 18,
                         text: "me, '24",
                         font: .caveat, weight: .bold, size: 14,
                         color: "#3F4A3A", align: .center),

                iconNode(heart, x: 168, y: 188, w: 36, h: 36,
                         glyph: "heart.fill",
                         plate: "#E8C28E", tint: "#C44536",
                         radius: 18, borderW: 1, borderC: "#3F4A3A"),

                dividerNode(div1, x: 24, y: 222, w: 272, h: 22,
                            style: .flowerChain, color: "#3F4A3A", thickness: 1.4),

                containerNode(notePanel, x: 24, y: 258, w: 272, h: 116,
                              bg: "#FBF5E5", radius: 6, borderW: 1, borderC: "#3F4A3A"),
                textNode(noteLabel, x: 36, y: 268, w: 248, h: 14,
                         text: "TODAY ·",
                         font: .fraunces, weight: .bold, size: 9,
                         color: "#C44536", align: .leading),
                textNode(note, x: 36, y: 284, w: 248, h: 80,
                         text: "pressing flowers,\nlearning to stretch canvas,\ndrawing the same lemon\nfor the seventh time —",
                         font: .caveat, weight: .bold, size: 18,
                         color: "#3F4A3A", align: .leading),

                textNode(worksLabel, x: 24, y: 388, w: 272, h: 14,
                         text: "— RECENT WORKS",
                         font: .fraunces, weight: .bold, size: 10,
                         color: "#3F4A3A", align: .leading),
                textNode(worksCount, x: 24, y: 388, w: 272, h: 14,
                         text: "04 · 12",
                         font: .fraunces, weight: .medium, size: 10,
                         color: "#9A8C72", align: .trailing),
                galleryNode(gallery, x: 24, y: 406, w: 272, h: 110,
                            tones: ["butter", "rose", "sage", "peach"],
                            gap: 6, radius: 4, borderW: 1, borderC: "#3F4A3A"),

                linkNode(link1, x: 24, y: 528, w: 272, h: 44,
                         text: "open studio · saturdays",
                         url: "wren.cucu/studio",
                         bg: "#FBF5E5", textColor: "#3F4A3A",
                         borderW: 1, borderC: "#3F4A3A", radius: 4),
                linkNode(link2, x: 24, y: 578, w: 130, h: 40,
                         text: "shop prints", url: "#",
                         bg: "#C44536", textColor: "#FBF5E5",
                         borderW: 1, borderC: "#3F4A3A", radius: 4),
                linkNode(link3, x: 162, y: 578, w: 134, h: 40,
                         text: "newsletter ✿", url: "#",
                         bg: nil, textColor: "#3F4A3A",
                         borderW: 1, borderC: "#3F4A3A", radius: 4),

                textNode(sig, x: 24, y: 626, w: 272, h: 14,
                         text: "with love, from the studio ✿",
                         font: .caveat, weight: .bold, size: 14,
                         color: "#C44536", align: .center),
            ]
        )
    }
}
