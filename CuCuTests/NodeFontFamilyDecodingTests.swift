//
//  NodeFontFamilyDecodingTests.swift
//  CuCuTests
//
//  Verifies that an unknown `fontFamily` raw value (i.e. a draft saved
//  on a future build that adds a new font case) decodes to `.system`
//  instead of throwing — so a forward-compatible field on a single
//  node never bricks a whole document load.
//

import Testing
import Foundation
@testable import CuCu

struct NodeFontFamilyDecodingTests {

    @Test func unknownFontFamilyRawValueFallsBackToSystem() throws {
        // `NodeStyle` JSON with a `fontFamily` value that isn't a
        // case in the current enum. Older binaries hitting newer
        // drafts must keep loading rather than throw.
        let json = """
        {
            "fontFamily": "futureFont42"
        }
        """.data(using: .utf8)!

        let style = try JSONDecoder().decode(NodeStyle.self, from: json)
        #expect(style.fontFamily == .system)
    }

    @Test func knownFontFamilyRawValueDecodesNormally() throws {
        // Sanity check — the custom decoder must not regress the
        // happy path. `"fraunces"` is a real case in the enum.
        let json = """
        {
            "fontFamily": "fraunces"
        }
        """.data(using: .utf8)!

        let style = try JSONDecoder().decode(NodeStyle.self, from: json)
        #expect(style.fontFamily == .fraunces)
    }

    @Test func nodeStyleWithUnknownFontFamilyDecodesWholeStyle() throws {
        // The original bug this guards: a draft saved on a future
        // build that adds a new font case must not brick a whole
        // document load on an older binary. The other tests cover
        // the enum in isolation; this one hits the integration path
        // — `NodeStyle.init(from:)` calling
        // `decodeIfPresent(NodeFontFamily.self, …)` against a JSON
        // body that mixes the unknown font with other style fields.
        let json = """
        {
            "backgroundColorHex": "#FBE9A8",
            "cornerRadius": 12,
            "borderWidth": 1.5,
            "borderColorHex": "#1A140E",
            "fontFamily": "futureFont42",
            "fontWeight": "bold",
            "fontSize": 22,
            "textColorHex": "#3A1A1F",
            "textAlignment": "center"
        }
        """.data(using: .utf8)!

        let style = try JSONDecoder().decode(NodeStyle.self, from: json)
        #expect(style.fontFamily == .system)

        // The other fields must still decode normally — the
        // forward-compat fallback should be scoped to the one bad
        // value, not silently swallow the whole node.
        #expect(style.backgroundColorHex == "#FBE9A8")
        #expect(style.cornerRadius == 12)
        #expect(style.borderWidth == 1.5)
        #expect(style.borderColorHex == "#1A140E")
        #expect(style.fontWeight == .bold)
        #expect(style.fontSize == 22)
        #expect(style.textColorHex == "#3A1A1F")
        #expect(style.textAlignment == .center)
    }

    @Test func encoderStillWritesRawValue() throws {
        // The custom decoder is `init(from:)` only — the synthesized
        // encoder must keep emitting the raw enum case. If someone
        // later adds a custom encoder that writes `"system"` on
        // unknown values, that breaks round-tripping on the
        // newer binary.
        var style = NodeStyle()
        style.fontFamily = .fraunces

        let data = try JSONEncoder().encode(style)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["fontFamily"] as? String == "fraunces")
    }
}
