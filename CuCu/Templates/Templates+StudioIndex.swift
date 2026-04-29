import Foundation

// Template 4 — Studio Index (portfolio)
//
// Clean designer/dev portfolio. Cream paper, navy ink, work-grid hero,
// role pills, asymmetric: avatar small top-left, name takes the right
// column. Source: TPL_PORTFOLIO.

extension TemplateBuilder {
    static func studioIndex() -> ProfileDocument {
        let avatar     = UUID()
        let status     = UUID()
        let statusSub  = UUID()
        let header     = UUID()
        let role       = UUID()
        let pill1      = UUID()
        let pill2      = UUID()
        let pill3      = UUID()
        let workLabel  = UUID()
        let workCount  = UUID()
        let gallery    = UUID()
        let div1       = UUID()
        let link1      = UUID()
        let link2      = UUID()
        let link3      = UUID()
        let foot       = UUID()
        let footR      = UUID()
        let foot2      = UUID()

        return assemble(
            bgColor: "#F2EEE3",
            bgPatternKey: nil,
            orderedNodes: [
                imageNode(avatar, x: 24, y: 32, w: 44, h: 44,
                          tone: "butter", radius: 22,
                          clip: .circle, borderW: 1, borderC: "#1F2D45"),

                textNode(status, x: 76, y: 32, w: 200, h: 14,
                         text: "● AVAILABLE FOR WORK",
                         font: .fraunces, weight: .semibold, size: 10,
                         color: "#3F7A52", align: .leading),
                textNode(statusSub, x: 76, y: 50, w: 200, h: 14,
                         text: "q3 / 2026 — booking sept",
                         font: .fraunces, weight: .regular, size: 11,
                         color: "#5A4F3F", align: .leading),

                textNode(header, x: 24, y: 92, w: 272, h: 48,
                         text: "Aria Hoshino",
                         font: .fraunces, weight: .bold, size: 32,
                         color: "#1F2D45", align: .leading),
                textNode(role, x: 24, y: 132, w: 272, h: 22,
                         text: "product designer & art director",
                         font: .fraunces, weight: .regular, size: 15,
                         color: "#5A4F3F", align: .leading),

                linkNode(pill1, x: 24, y: 164, w: 70, h: 26,
                         text: "identity", url: "#",
                         bg: "#FFFFFF", textColor: "#1F2D45",
                         borderW: 1, borderC: "#1F2D45", radius: 13,
                         font: .fraunces, weight: .medium, size: 12),
                linkNode(pill2, x: 100, y: 164, w: 64, h: 26,
                         text: "web", url: "#",
                         bg: "#FFFFFF", textColor: "#1F2D45",
                         borderW: 1, borderC: "#1F2D45", radius: 13,
                         font: .fraunces, weight: .medium, size: 12),
                linkNode(pill3, x: 170, y: 164, w: 84, h: 26,
                         text: "editorial", url: "#",
                         bg: "#1F2D45", textColor: "#F2EEE3",
                         borderW: 1, borderC: "#1F2D45", radius: 13,
                         font: .fraunces, weight: .medium, size: 12),

                textNode(workLabel, x: 24, y: 208, w: 200, h: 14,
                         text: "— SELECTED WORK",
                         font: .fraunces, weight: .bold, size: 11,
                         color: "#1F2D45", align: .leading),
                textNode(workCount, x: 24, y: 208, w: 272, h: 14,
                         text: "12 PROJECTS",
                         font: .fraunces, weight: .medium, size: 10,
                         color: "#9A8C72", align: .trailing),

                galleryNode(gallery, x: 24, y: 230, w: 272, h: 200,
                            tones: ["butter", "sky", "sage", "peach"],
                            gap: 4, radius: 8, borderW: 1, borderC: "#1F2D45"),

                dividerNode(div1, x: 24, y: 446, w: 272, h: 4,
                            style: .solid, color: "#1F2D45", thickness: 1),

                linkNode(link1, x: 24, y: 460, w: 272, h: 44,
                         text: "View case studies →",
                         url: "aria.cucu/work",
                         bg: "#1F2D45", textColor: "#F2EEE3",
                         borderW: 0, borderC: "#1F2D45", radius: 0),
                linkNode(link2, x: 24, y: 510, w: 132, h: 44,
                         text: "Email", url: "mailto:hello",
                         bg: nil, textColor: "#1F2D45",
                         borderW: 1, borderC: "#1F2D45", radius: 0),
                linkNode(link3, x: 164, y: 510, w: 132, h: 44,
                         text: "Read.cv", url: "aria.cucu/cv",
                         bg: nil, textColor: "#1F2D45",
                         borderW: 1, borderC: "#1F2D45", radius: 0),

                textNode(foot, x: 24, y: 580, w: 272, h: 14,
                         text: "TOKYO · NEW YORK",
                         font: .fraunces, weight: .semibold, size: 10,
                         color: "#5A4F3F", align: .leading),
                textNode(footR, x: 24, y: 580, w: 272, h: 14,
                         text: "↗ aria.studio",
                         font: .fraunces, weight: .semibold, size: 10,
                         color: "#5A4F3F", align: .trailing),
                textNode(foot2, x: 24, y: 596, w: 272, h: 14,
                         text: "+12 years independent practice",
                         font: .fraunces, weight: .regular, size: 11,
                         color: "#9A8C72", align: .leading),
            ]
        )
    }
}
