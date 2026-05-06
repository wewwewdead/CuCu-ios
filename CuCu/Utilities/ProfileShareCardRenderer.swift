import UIKit

/// Renders a premium *editorial identity card* — the artifact a user
/// shares to Stories, TikTok, or DMs to point friends at their CuCu.
///
/// The card is composed in two stages:
///
/// 1. The user's profile page is snapshotted off-screen (same v2 canvas
///    pipeline used by the live editor and viewer) into a "phone preview"
///    image. Images embedded in the document are preloaded with a small
///    concurrency budget so the snapshot doesn't spike memory.
/// 2. That preview is drawn into a fixed 1080×1620 portrait card on a
///    warm-paper ground, framed like a print in a gallery matte, with a
///    tasteful identity block and a small "Made with CuCu" footer.
///
/// The output is intentionally a 2:3 portrait — taller than a square
/// post but narrower than a Story canvas — so it reads as a *collectible
/// card*, not a screen template. Stories users can pad it further inside
/// their own editor; the card itself stays restrained.
///
/// **Memory & concurrency:**
///   - Single 1080×1620 RGBA compose buffer (~7 MB).
///   - Inner snapshot is capped at scale 2.0 (downsampled by `draw(in:)`
///     into a ~380pt-wide slot, so any extra density is wasted).
///   - Image preload uses the same throttle as before
///     (`maxConcurrentImageLoads`) and the same 4 s safety timeout.
///   - All drawing runs on the main actor; `CanvasImageLoader` already
///     dispatches its callbacks to main, so the throttling state needs
///     no additional locking.
///
/// **Fallbacks:**
///   - No avatar in the document → an elegant Fraunces monogram against a
///     rose ground, drawn in the same circular slot.
///   - No display name → the @username doubles as the headline.
///   - Inner snapshot fails (layout error, missing asset, etc.) → an
///     abstract gallery panel fills the matte, keyed by the username's
///     monogram. The user still gets a beautiful, shareable card.
///   - The renderer only throws on a truly empty document (caller's
///     contract), so a failure inside the snapshot path never bubbles
///     up as a "card unavailable" error.
@MainActor
enum ProfileShareCardRenderer {
    static let cardWidth: CGFloat = 1080
    static let cardHeight: CGFloat = 1620

    private static let imagePreloadTimeout: TimeInterval = 4
    private static let renderSettleDelayNanoseconds: UInt64 = 300_000_000
    /// Hard cap on inflight async image loads during preload. Prior to
    /// this throttle, profiles with dozens of gallery photos could spike
    /// memory by decoding every image in parallel — a 50-image profile
    /// would land 50 simultaneous `loadAsync` callbacks, each with a
    /// decoded UIImage in flight. Six is a balance against the
    /// hardcoded 4s timeout: fast enough to clear typical profiles in
    /// time, slow enough that a worst-case profile no longer peaks
    /// memory in OOM territory mid-share.
    private static let maxConcurrentImageLoads = 6

    static func render(
        username: String,
        profileLink: String,
        document: ProfileDocument?,
        vibe: ProfileVibe? = nil
    ) async throws -> UIImage {
        await Task.yield()
        guard let document, !document.pages.isEmpty else {
            throw ProfileShareCardRenderingError.missingDocument
        }
        await preloadImages(in: document)

        // Best-effort inner snapshot. If layout / decode fails for any
        // reason, the composer falls through to an abstract panel — the
        // user never sees a hard failure here.
        let preview: UIImage? = try? await renderPagePreview(
            document: document,
            pageIndex: 0
        )

        let identity = resolveIdentity(
            username: username,
            document: document,
            vibe: vibe
        )

        return composeCard(preview: preview, identity: identity)
    }

    // MARK: - Inner profile snapshot

    private static func renderPagePreview(document: ProfileDocument, pageIndex: Int) async throws -> UIImage {
        let page = document.pages[pageIndex]
        let designWidth = max(
            1,
            CGFloat(document.contentDesignWidth(forPageAt: pageIndex))
        )
        let pageHeight = max(1, CGFloat(page.height))

        let canvas = CanvasEditorView()
        canvas.isInteractive = false
        canvas.viewerPageIndex = pageIndex
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: designWidth, height: pageHeight))
        canvas.bounds = CGRect(origin: .zero, size: canvas.frame.size)
        canvas.apply(document: document, selectedID: nil)
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()

        // Give UIKit and any background-image effect renders one short,
        // non-blocking settle window. Image bytes are prewarmed above,
        // so this is mainly for layout, Core Animation, and filtered
        // bg swaps.
        try? await Task.sleep(nanoseconds: renderSettleDelayNanoseconds)
        canvas.layoutIfNeeded()

        // Snapshot at scale 2.0. The phone preview lands in a ~380pt-
        // wide slot inside the 1080-wide card, so any density beyond
        // 2× is wasted memory before being downsampled by `draw(in:)`.
        guard let image = canvas.snapshotRenderedPage(at: pageIndex, scale: 2.0) else {
            throw ProfileShareCardRenderingError.renderingFailed
        }
        return image
    }

    // MARK: - Identity resolution

    private struct Identity {
        let displayName: String
        let handle: String
        let monogram: String
        let avatar: UIImage?
        let vibe: ProfileVibe?
        let hasExplicitDisplayName: Bool
    }

    private static func resolveIdentity(
        username: String,
        document: ProfileDocument?,
        vibe: ProfileVibe?
    ) -> Identity {
        let normalizedHandle = ProfileShareLink.normalizedUsername(username)

        var explicitName: String? = nil
        if let document,
           let id = StructuredProfileLayout.roleID(.profileName, in: document),
           let raw = document.nodes[id]?.content.text {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { explicitName = trimmed }
        }
        let displayName = explicitName ?? "@\(normalizedHandle)"

        let monogram = makeMonogram(displayName: explicitName ?? normalizedHandle, fallbackHandle: normalizedHandle)

        var avatar: UIImage? = nil
        if let document,
           let id = StructuredProfileLayout.roleID(.profileAvatar, in: document),
           let path = document.nodes[id]?.content.localImagePath {
            avatar = LocalCanvasAssetStore.loadUIImage(path)
        }

        return Identity(
            displayName: displayName,
            handle: normalizedHandle,
            monogram: monogram,
            avatar: avatar,
            vibe: vibe,
            hasExplicitDisplayName: explicitName != nil
        )
    }

    private static func makeMonogram(displayName: String, fallbackHandle: String) -> String {
        let cleaned = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))
        )
        let words = cleaned
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
        let initials = words.compactMap { $0.first }.map { String($0).uppercased() }
        if !initials.isEmpty { return initials.joined() }
        if let first = fallbackHandle.first { return String(first).uppercased() }
        return "C"
    }

    // MARK: - Composition

    private static func composeCard(preview: UIImage?, identity: Identity) -> UIImage {
        let size = CGSize(width: cardWidth, height: cardHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            // 1. Warm paper ground
            drawWarmBackground(in: CGRect(origin: .zero, size: size), ctx: cg)

            // 2. Outer card-on-card frame
            let cardRect = CGRect(origin: .zero, size: size).insetBy(dx: 36, dy: 36)
            drawMainCard(in: cardRect, ctx: cg)

            // 3. Top editorial label
            let labelRect = CGRect(
                x: cardRect.minX,
                y: cardRect.minY + 78,
                width: cardRect.width,
                height: 32
            )
            drawEditorialLabel("✦   CUCU IDENTITY   ✦", in: labelRect)

            // 4. Art-print matte + phone preview
            let matteWidth: CGFloat = cardRect.width - 96
            let matteHeight: CGFloat = 1000
            let matteRect = CGRect(
                x: cardRect.midX - matteWidth / 2,
                y: cardRect.minY + 144,
                width: matteWidth,
                height: matteHeight
            )
            drawArtMatte(in: matteRect, ctx: cg)

            let phoneHeight: CGFloat = matteRect.height - 96
            let phoneWidth: CGFloat = phoneHeight * 0.41
            let phoneRect = CGRect(
                x: matteRect.midX - phoneWidth / 2,
                y: matteRect.midY - phoneHeight / 2,
                width: phoneWidth,
                height: phoneHeight
            )
            if let preview {
                drawPhonePreview(preview, in: phoneRect, ctx: cg)
            } else {
                drawAbstractPhonePreview(in: phoneRect, identity: identity, ctx: cg)
            }

            // 5. Identity block (divider rule + avatar + name + handle + pill)
            let blockTop = matteRect.maxY + 30
            drawDividerRule(
                from: CGPoint(x: cardRect.minX + 56, y: blockTop),
                length: cardRect.width - 112,
                alpha: 0.12,
                ctx: cg
            )
            let identityRect = CGRect(
                x: cardRect.minX + 56,
                y: blockTop + 8,
                width: cardRect.width - 112,
                height: 220
            )
            drawIdentityBlock(in: identityRect, identity: identity, ctx: cg)

            // 6. Footer
            let footerDividerY = cardRect.maxY - 96
            drawDividerRule(
                from: CGPoint(x: cardRect.minX + 56, y: footerDividerY),
                length: cardRect.width - 112,
                alpha: 0.10,
                ctx: cg
            )
            let footerRect = CGRect(
                x: cardRect.minX,
                y: cardRect.maxY - 70,
                width: cardRect.width,
                height: 40
            )
            drawFooter(in: footerRect)
        }
    }

    private static func drawWarmBackground(in rect: CGRect, ctx: CGContext) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            UIColor(red: 0.965, green: 0.945, blue: 0.886, alpha: 1).cgColor,
            UIColor(red: 0.918, green: 0.886, blue: 0.812, alpha: 1).cgColor
        ] as CFArray
        guard let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else {
            UIColor.cucuPaper.setFill()
            UIBezierPath(rect: rect).fill()
            return
        }
        ctx.saveGState()
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
        ctx.restoreGState()
    }

    private static func drawMainCard(in rect: CGRect, ctx: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 28)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 14),
            blur: 36,
            color: UIColor(white: 0, alpha: 0.10).cgColor
        )
        UIColor.cucuCard.setFill()
        path.fill()
        ctx.restoreGState()

        // Outer hairline
        UIColor.cucuInk.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Inner hairline at 14pt inset — the "card-on-card" depth that
        // makes the surface read as a paper insert rather than a flat
        // rectangle.
        let inner = UIBezierPath(
            roundedRect: rect.insetBy(dx: 14, dy: 14),
            cornerRadius: 18
        )
        UIColor.cucuInk.withAlphaComponent(0.06).setStroke()
        inner.lineWidth = 1
        inner.stroke()
    }

    private static func drawEditorialLabel(_ string: String, in rect: CGRect) {
        let font = UIFont(name: "Lexend-SemiBold", size: 22)
            ?? UIFont.systemFont(ofSize: 22, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.cucuInk.withAlphaComponent(0.42),
            .paragraphStyle: para,
            .kern: 6
        ]
        (string as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        )
    }

    private static func drawArtMatte(in rect: CGRect, ctx: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 20)
        UIColor.cucuPaperDeep.setFill()
        path.fill()
        UIColor.cucuInk.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func drawPhonePreview(_ image: UIImage, in rect: CGRect, ctx: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 26)

        // Soft drop shadow under the print, drawn by filling a cream
        // base behind the eventual image clip.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 18),
            blur: 28,
            color: UIColor(white: 0, alpha: 0.18).cgColor
        )
        UIColor.cucuCard.setFill()
        path.fill()
        ctx.restoreGState()

        // AspectFill, top-anchored — the hero (avatar / display name)
        // is what makes the preview legible at this size, so we always
        // keep the top of the page in frame even when the image is
        // taller than the slot.
        ctx.saveGState()
        path.addClip()

        let imgSize = image.size
        if imgSize.width > 0, imgSize.height > 0 {
            let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
            let dw = imgSize.width * scale
            let dh = imgSize.height * scale
            image.draw(in: CGRect(
                x: rect.midX - dw / 2,
                y: rect.minY,
                width: dw,
                height: dh
            ))
        }
        ctx.restoreGState()

        UIColor.cucuInk.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private static func drawAbstractPhonePreview(in rect: CGRect, identity: Identity, ctx: CGContext) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 26)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 18),
            blur: 28,
            color: UIColor(white: 0, alpha: 0.18).cgColor
        )
        UIColor.cucuCard.setFill()
        path.fill()
        ctx.restoreGState()

        ctx.saveGState()
        path.addClip()

        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            UIColor.cucuRose.cgColor,
            UIColor.cucuShell.cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        } else {
            UIColor.cucuRose.setFill()
            UIBezierPath(rect: rect).fill()
        }

        let glyphSize = rect.width * 0.62
        let glyphFont = UIFont(name: "Fraunces-Bold", size: glyphSize)
            ?? UIFont.boldSystemFont(ofSize: glyphSize)
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: glyphFont,
            .foregroundColor: UIColor(red: 0.29, green: 0.09, blue: 0.13, alpha: 1)
        ]
        let glyph = NSAttributedString(string: identity.monogram, attributes: glyphAttrs)
        let gs = glyph.size()
        glyph.draw(at: CGPoint(
            x: rect.midX - gs.width / 2,
            y: rect.midY - gs.height / 2 - 12
        ))

        let captionFont = UIFont(name: "Lexend-SemiBold", size: 22)
            ?? UIFont.systemFont(ofSize: 22, weight: .semibold)
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: UIColor.cucuInk.withAlphaComponent(0.55),
            .kern: 2
        ]
        let caption = NSAttributedString(string: "@\(identity.handle)", attributes: captionAttrs)
        let cs2 = caption.size()
        caption.draw(at: CGPoint(
            x: rect.midX - cs2.width / 2,
            y: rect.maxY - 60
        ))

        ctx.restoreGState()

        UIColor.cucuInk.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private static func drawDividerRule(from origin: CGPoint, length: CGFloat, alpha: CGFloat, ctx: CGContext) {
        UIColor.cucuInk.withAlphaComponent(alpha).setStroke()
        let path = UIBezierPath()
        path.lineWidth = 1
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + length, y: origin.y))
        path.stroke()
    }

    private static func drawIdentityBlock(in rect: CGRect, identity: Identity, ctx: CGContext) {
        let avatarSize: CGFloat = 132
        let avatarRect = CGRect(
            x: rect.minX + 4,
            y: rect.minY + 28,
            width: avatarSize,
            height: avatarSize
        )
        drawAvatar(identity.avatar, in: avatarRect, monogram: identity.monogram, ctx: ctx)

        let textX = avatarRect.maxX + 28
        let textW = rect.maxX - textX

        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingTail

        let nameFont = UIFont(name: "Fraunces-Bold", size: 50)
            ?? UIFont.boldSystemFont(ofSize: 50)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: UIColor.cucuInk,
            .paragraphStyle: para
        ]
        let nameRect = CGRect(x: textX, y: avatarRect.minY + 4, width: textW, height: 64)
        (identity.displayName as NSString).draw(
            with: nameRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: nameAttrs,
            context: nil
        )

        let handleFont = UIFont(name: "Lexend-Medium", size: 28)
            ?? UIFont.systemFont(ofSize: 28, weight: .medium)
        let handleAttrs: [NSAttributedString.Key: Any] = [
            .font: handleFont,
            .foregroundColor: UIColor.cucuInkSoft.withAlphaComponent(0.82),
            .paragraphStyle: para
        ]
        let handleRect = CGRect(x: textX, y: nameRect.maxY + 2, width: textW, height: 36)
        // Skip the redundant "@handle" line when the display name *is*
        // the @handle — keeps the identity block tight rather than
        // restating the same string twice.
        if identity.hasExplicitDisplayName {
            ("@\(identity.handle)" as NSString).draw(
                with: handleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: handleAttrs,
                context: nil
            )
        }

        if let vibe = identity.vibe {
            let pillTopY = (identity.hasExplicitDisplayName ? handleRect.maxY : nameRect.maxY) + 14
            drawVibePill(vibe.label, at: CGPoint(x: textX, y: pillTopY))
        }
    }

    private static func drawAvatar(_ image: UIImage?, in rect: CGRect, monogram: String, ctx: CGContext) {
        let path = UIBezierPath(ovalIn: rect)

        if let image {
            ctx.saveGState()
            path.addClip()
            let imgSize = image.size
            if imgSize.width > 0, imgSize.height > 0 {
                let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
                let dw = imgSize.width * scale
                let dh = imgSize.height * scale
                image.draw(in: CGRect(
                    x: rect.midX - dw / 2,
                    y: rect.midY - dh / 2,
                    width: dw,
                    height: dh
                ))
            }
            ctx.restoreGState()
        } else {
            UIColor.cucuRose.setFill()
            path.fill()
            let font = UIFont(name: "Fraunces-Bold", size: rect.height * 0.42)
                ?? UIFont.boldSystemFont(ofSize: rect.height * 0.42)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(red: 0.29, green: 0.09, blue: 0.13, alpha: 1),
                .paragraphStyle: para
            ]
            let str = NSAttributedString(string: monogram, attributes: attrs)
            let s = str.size()
            str.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
        }

        UIColor.cucuInk.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private static func drawVibePill(_ label: String, at origin: CGPoint) {
        let font = UIFont(name: "Lexend-SemiBold", size: 20)
            ?? UIFont.systemFont(ofSize: 20, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 0.29, green: 0.09, blue: 0.13, alpha: 1),
            .kern: 1
        ]
        let str = NSAttributedString(string: "✦  \(label)", attributes: attrs)
        let textSize = str.size()
        let padH: CGFloat = 20
        let padV: CGFloat = 10
        let pillRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textSize.width + padH * 2,
            height: textSize.height + padV * 2
        )
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
        UIColor.cucuRose.setFill()
        pillPath.fill()
        UIColor.cucuRose.withAlphaComponent(0.55).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()
        str.draw(at: CGPoint(x: pillRect.minX + padH, y: pillRect.minY + padV))
    }

    private static func drawFooter(in rect: CGRect) {
        let font = UIFont(name: "Fraunces-Italic", size: 26)
            ?? UIFont.italicSystemFont(ofSize: 26)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.cucuInk.withAlphaComponent(0.55),
            .paragraphStyle: para,
            .kern: 1
        ]
        ("✦   Made with CuCu   ✦" as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        )
    }

    // MARK: - Image preload (carried over from the prior implementation)

    private static func preloadImages(in document: ProfileDocument) async {
        let paths = imagePaths(in: document)
        guard !paths.isEmpty else { return }

        // Drop already-cached entries before we touch the async path
        // — every sync hit is a free win and shrinks the throttle queue.
        let pendingPaths = paths.filter { CanvasImageLoader.loadSync($0) == nil }
        guard !pendingPaths.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Mutable state below is touched only on the main thread —
            // CanvasImageLoader's completion is dispatched to main, and
            // the renderer itself is `@MainActor`. No additional lock
            // is needed.
            var queue = pendingPaths
            var active = 0
            var completed = 0
            let total = pendingPaths.count
            var didResume = false

            func resumeOnce() {
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }

            func startNext() {
                while active < maxConcurrentImageLoads, !queue.isEmpty {
                    let path = queue.removeFirst()
                    active += 1
                    CanvasImageLoader.loadAsync(path) { _ in
                        active -= 1
                        completed += 1
                        if completed >= total {
                            resumeOnce()
                        } else {
                            startNext()
                        }
                    }
                }
            }

            startNext()

            // Safety net: if a load callback never fires (the loader
            // could in theory drop a request), the timeout still
            // unblocks the renderer at the original 4s mark.
            DispatchQueue.main.asyncAfter(deadline: .now() + imagePreloadTimeout) {
                resumeOnce()
            }
        }
    }

    private static func imagePaths(in document: ProfileDocument) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        func append(_ path: String?) {
            guard let path, !path.isEmpty, seen.insert(path).inserted else { return }
            paths.append(path)
        }

        for page in document.pages {
            append(page.backgroundImagePath)
        }
        append(document.pageBackgroundImagePath)

        for node in document.nodes.values {
            append(node.style.backgroundImagePath)
            append(node.content.localImagePath)
            for path in node.content.imagePaths ?? [] {
                append(path)
            }
        }

        return paths
    }
}

enum ProfileShareCardRenderingError: LocalizedError {
    case missingDocument
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .missingDocument:
            return "There's no profile design to export yet."
        case .renderingFailed:
            return "Couldn't make the profile card right now."
        }
    }
}
