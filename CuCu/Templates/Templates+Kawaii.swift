import Foundation

// Template 1 — Kawaii (Sugar Bun)
//
// Hyper-cute, pastel, sticker-collage. Pink + butter + mint, hearts
// everywhere, hand-script bio in Caveat, Lobster header. Source:
// `design-mocks/cucu-templates/templates.jsx` TPL_KAWAII.

extension TemplateBuilder {
    static func kawaii() -> ProfileDocument {
        let blob1   = UUID()
        let blob2   = UUID()
        let header  = UUID()
        let sub     = UUID()
        let avatar  = UUID()
        let stick1  = UUID()
        let stick2  = UUID()
        let bio     = UUID()
        let div1    = UUID()
        let icon1   = UUID()
        let icon2   = UUID()
        let icon3   = UUID()
        let gallery = UUID()
        let link1   = UUID()
        let link2   = UUID()
        let sig     = UUID()

        return assemble(
            bgColor: "#FFE5EE",
            bgPatternKey: "hearts",
            orderedNodes: [
                containerNode(blob1, x: 30, y: 92, w: 130, h: 130,
                              bg: "#FFF1B8", radius: 65, borderW: 2, borderC: "#3A1A26"),
                containerNode(blob2, x: 175, y: 110, w: 110, h: 110,
                              bg: "#D8E9C9", radius: 55, borderW: 2, borderC: "#3A1A26"),

                textNode(header, x: 24, y: 30, w: 272, h: 56,
                         text: "sugar bun ♡",
                         font: .lobster, weight: .regular, size: 42,
                         color: "#B8324B", align: .center),
                textNode(sub, x: 24, y: 78, w: 272, h: 18,
                         text: "ﾟ✿ﾟ ・♡ welcome to my corner ♡・ ﾟ✿ﾟ",
                         font: .patrickHand, weight: .regular, size: 13,
                         color: "#3A1A26", align: .center),

                imageNode(avatar, x: 50, y: 110, w: 96, h: 96,
                          tone: "rose", radius: 48,
                          clip: .circle, borderW: 3, borderC: "#3A1A26"),

                iconNode(stick1, x: 130, y: 100, w: 36, h: 36,
                         glyph: "heart.fill",
                         plate: "#FFFFFF", tint: "#B8324B",
                         radius: 18, borderW: 2, borderC: "#3A1A26"),
                iconNode(stick2, x: 260, y: 88, w: 32, h: 32,
                         glyph: "sparkle",
                         plate: "#FFFFFF", tint: "#D2557A",
                         radius: 16, borderW: 2, borderC: "#3A1A26"),

                textNode(bio, x: 175, y: 130, w: 110, h: 70,
                         text: "collector of\nsmall joys &\nplush bunnies",
                         font: .caveat, weight: .bold, size: 16,
                         color: "#3A1A26", align: .center),

                dividerNode(div1, x: 30, y: 240, w: 260, h: 22,
                            style: .heartChain, color: "#B8324B", thickness: 1.6),

                iconNode(icon1, x: 50, y: 274, w: 56, h: 56,
                         glyph: "heart.fill",
                         plate: "#FFD9E5", tint: "#B8324B",
                         radius: 28, borderW: 2, borderC: "#3A1A26"),
                iconNode(icon2, x: 132, y: 274, w: 56, h: 56,
                         glyph: "star.fill",
                         plate: "#FFF1B8", tint: "#D2557A",
                         radius: 28, borderW: 2, borderC: "#3A1A26"),
                iconNode(icon3, x: 214, y: 274, w: 56, h: 56,
                         glyph: "camera.macro",
                         plate: "#D8E9C9", tint: "#3F7A52",
                         radius: 28, borderW: 2, borderC: "#3A1A26"),

                galleryNode(gallery, x: 36, y: 350, w: 248, h: 110,
                            tones: ["rose", "butter", "sage", "peach"],
                            gap: 6, radius: 14, borderW: 2, borderC: "#3A1A26"),

                linkNode(link1, x: 36, y: 478, w: 248, h: 44,
                         text: "my plushie shop ♡",
                         url: "sugarbun.cucu/shop",
                         bg: "#FFFFFF", textColor: "#B8324B",
                         borderW: 2, borderC: "#3A1A26", radius: 22),
                linkNode(link2, x: 36, y: 532, w: 248, h: 44,
                         text: "sticker swap",
                         url: "sugarbun.cucu/swap",
                         bg: "#B8324B", textColor: "#FFFFFF",
                         borderW: 2, borderC: "#3A1A26", radius: 22),

                textNode(sig, x: 30, y: 590, w: 260, h: 18,
                         text: "⊹  thanks for visiting!  ⊹",
                         font: .patrickHand, weight: .regular, size: 12,
                         color: "#3A1A26", align: .center),
            ]
        )
    }
}
