import Foundation

// Template 2 — Minimalist (White Room)
//
// Editorial, restrained. Off-white, near-black ink, generous whitespace,
// a single hairline rule. Yeseva display + Fraunces body; no decoration
// beyond a thin running mono caption. Source: TPL_MINIMAL.

extension TemplateBuilder {
    static func minimalist() -> ProfileDocument {
        let runner       = UUID()
        let runnerR      = UUID()
        let avatar       = UUID()
        let header       = UUID()
        let div1         = UUID()
        let role         = UUID()
        let bio          = UUID()
        let contactLabel = UUID()
        let link1        = UUID()
        let link2        = UUID()
        let link3        = UUID()
        let colo         = UUID()
        let coloR        = UUID()

        return assemble(
            bgColor: "#FBF8F2",
            bgPatternKey: nil,
            orderedNodes: [
                textNode(runner, x: 24, y: 32, w: 200, h: 14,
                         text: "— PROFILE NO. 042 / 26",
                         font: .fraunces, weight: .regular, size: 10,
                         color: "#9A9A9A", align: .leading),
                textNode(runnerR, x: 96, y: 32, w: 200, h: 14,
                         text: "EST. 2026",
                         font: .fraunces, weight: .medium, size: 10,
                         color: "#9A9A9A", align: .trailing),

                imageNode(avatar, x: 240, y: 62, w: 56, h: 56,
                          tone: "sage", radius: 28,
                          clip: .circle, borderW: 1, borderC: "#1A1A1A"),

                textNode(header, x: 24, y: 92, w: 210, h: 130,
                         text: "theo\nclark.",
                         font: .yesevaOne, weight: .regular, size: 56,
                         color: "#1A1A1A", align: .leading),

                dividerNode(div1, x: 24, y: 240, w: 272, h: 2,
                            style: .solid, color: "#1A1A1A", thickness: 1),

                textNode(role, x: 24, y: 252, w: 272, h: 16,
                         text: "WRITER · EDITOR · QUIET TYPE",
                         font: .fraunces, weight: .semibold, size: 11,
                         color: "#1A1A1A", align: .leading),

                textNode(bio, x: 24, y: 282, w: 272, h: 90,
                         text: "I write slow essays on\nrooms, light, and the\nthings people leave\nbehind.",
                         font: .fraunces, weight: .regular, size: 18,
                         color: "#3A3A3A", align: .leading),

                textNode(contactLabel, x: 24, y: 388, w: 272, h: 14,
                         text: "INDEX",
                         font: .fraunces, weight: .semibold, size: 10,
                         color: "#9A9A9A", align: .leading),

                linkNode(link1, x: 24, y: 408, w: 272, h: 50,
                         text: "01  Recent essays  →",
                         url: "theo.cucu/essays",
                         bg: nil, textColor: "#1A1A1A",
                         borderW: 1, borderC: "#1A1A1A", radius: 0,
                         font: .fraunces, weight: .semibold, size: 16, align: .center),
                linkNode(link2, x: 24, y: 460, w: 272, h: 50,
                         text: "02  Field notes  →",
                         url: "theo.cucu/notes",
                         bg: nil, textColor: "#1A1A1A",
                         borderW: 1, borderC: "#1A1A1A", radius: 0,
                         font: .fraunces, weight: .semibold, size: 16, align: .center),
                linkNode(link3, x: 24, y: 512, w: 272, h: 50,
                         text: "03  Correspondence  →",
                         url: "theo.cucu/mail",
                         bg: nil, textColor: "#1A1A1A",
                         borderW: 1, borderC: "#1A1A1A", radius: 0,
                         font: .fraunces, weight: .semibold, size: 16, align: .center),

                textNode(colo, x: 24, y: 600, w: 272, h: 14,
                         text: "SET IN YESEVA · FRAUNCES",
                         font: .fraunces, weight: .medium, size: 9,
                         color: "#9A9A9A", align: .leading),
                textNode(coloR, x: 24, y: 600, w: 272, h: 14,
                         text: "PG. 01",
                         font: .fraunces, weight: .medium, size: 9,
                         color: "#9A9A9A", align: .trailing),
            ]
        )
    }
}
