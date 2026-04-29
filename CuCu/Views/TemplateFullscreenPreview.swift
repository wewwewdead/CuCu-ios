import SwiftData
import SwiftUI

// MARK: - Fullscreen template preview
//
// Detail view that opens when the user taps "Preview" on a template
// card. Mirrors the prototype's `TemplatePreview` (`templates-picker.jsx`)
// but adapts the desk-style 3-column layout (left vibe rail, center
// device, right replace rail) to a vertical stack — at iPhone widths
// the rails don't have room to live alongside a full-size device.
//
// Top header carries `← Back` (returns to the picker) and `Use this
// template` (fires the same confirmation alert + apply flow as the
// card's Use-this button, hosted locally so the preview can stay open
// or dismiss based on the result).
//
// Body, top to bottom:
//   1. Eyebrow ("PREVIEW · 0X of N") + italic template name
//   2. Vibe italic line + four palette dots
//   3. Mini iPhone bezel rendering the actual `ProfileDocument` at
//      scale 0.78 — fills most of the screen width without forcing
//      horizontal scroll on a standard iPhone
//   4. "REPLACE" mono caps + checklist of placeholders the user will
//      swap in (avatar, name & bio, links, gallery, icons)
//   5. Handwritten tip in a dashed-border note panel

struct TemplateFullscreenPreview: View {
    let template: ProfileTemplate
    /// Returning `true` dismisses both this preview and the picker
    /// underneath (success path); returning `false` keeps everything on
    /// screen and surfaces the error inside the picker.
    let onApply: (ProfileTemplate) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.cucuWidthClass) private var widthClass
    @State private var showingConfirmation = false

    var body: some View {
        let document = decodeTemplateDocument(template)
        let spec = DefaultTemplates.spec(for: template.id)

        VStack(spacing: 0) {
            header
            Divider().background(Color.cucuInkRule)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleBlock(spec: spec)
                    if let spec { vibeBlock(spec: spec) }
                    devicePreview(document: document)
                        .frame(maxWidth: .infinity, alignment: .center)
                    replaceList
                    tipPanel
                }
                .padding(.horizontal, CucuSpacing.screenInset(widthClass))
                .padding(.vertical, CucuSpacing.sectionGap(widthClass))
                .frame(maxWidth: widthClass == .iPad ? CucuLayoutCap.modalContent : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.cucuPaper.ignoresSafeArea())
        .cucuWidthClass()
        .alert(
            "Replace current canvas?",
            isPresented: $showingConfirmation,
            actions: {
                Button("Cancel", role: .cancel) {}
                Button("Apply", role: .destructive) {
                    if onApply(template) {
                        dismiss()
                    }
                }
            },
            message: {
                Text("This replaces the current canvas design. The draft title stays the same.")
            }
        )
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                }
                .font(.cucuSans(13, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Color.cucuCardSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.cucuInkRule, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                showingConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    // "Use this template" + chevron + 36pt of padding
                    // overflows alongside the Back button on iPhone SE.
                    // Abbreviate on compact so both buttons sit
                    // comfortably; full label on regular and up.
                    Text(widthClass.isCompact ? "Use this" : "Use this template")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.7)
                }
                .font(.cucuSans(13.5, weight: .semibold))
                .foregroundStyle(Color.cucuCard)
                .padding(.horizontal, widthClass.isCompact ? 14 : 18)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cucuInk)
                )
                .shadow(color: Color.cucuCherry, radius: 0, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CucuSpacing.screenInset(widthClass))
        .padding(.vertical, 12)
        .background(Color.cucuCard)
    }

    // MARK: title

    @ViewBuilder
    private func titleBlock(spec: DefaultTemplateSpec?) -> some View {
        let total = DefaultTemplates.all.count
        let index = (DefaultTemplates.all.firstIndex(where: { $0.id == template.id }) ?? 0) + 1
        let label = spec != nil ? "PREVIEW · 0\(index) of \(total)" : "PREVIEW · SAVED"

        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.cucuMono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Color.cucuInkFaded)
            Text(template.name)
                .font(.cucuEditorial(28, weight: .semibold))
                .italic()
                .foregroundStyle(Color.cucuInk)
        }
    }

    // MARK: vibe

    private func vibeBlock(spec: DefaultTemplateSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.vibe)
                .font(.cucuEditorial(17, weight: .regular))
                .italic()
                .foregroundStyle(Color.cucuInkSoft)

            HStack(spacing: 8) {
                ForEach(Array(spec.swatch.enumerated()), id: \.offset) { _, hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().strokeBorder(Color.cucuInkRule, lineWidth: 1))
                        .frame(width: 18, height: 18)
                }
                Spacer()
            }
        }
    }

    // MARK: device

    @ViewBuilder
    private func devicePreview(document: ProfileDocument?) -> some View {
        // Scale picked so the bezel + content fits a typical iPhone
        // width (~393pt) with comfortable horizontal padding. 0.78 ×
        // 390pt page → 304pt visible canvas, plus 12pt bezel padding =
        // 316pt total — leaves a small breathing margin on each side.
        let scale: CGFloat = 0.78
        let pageWidth: CGFloat = CGFloat(document?.pageWidth ?? 390)
        let pageHeight: CGFloat = CGFloat(document?.pages.first?.height ?? document?.pageHeight ?? 805)

        MiniDeviceFrame(cornerRadius: 36, bezelThickness: 8) {
            if let document {
                TplCanvasView(document: document, scale: scale)
            } else {
                Color.cucuPaperDeep
            }
        }
        .frame(width: pageWidth * scale + 16,
               height: pageHeight * scale + 16)
    }

    // MARK: replace list

    private var replaceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REPLACE")
                .font(.cucuMono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Color.cucuInkFaded)

            VStack(alignment: .leading, spacing: 10) {
                replaceRow(symbol: "circle.lefthalf.filled", text: "Profile photo")
                replaceRow(symbol: "textformat", text: "Your name & bio")
                replaceRow(symbol: "link", text: "Your links")
                replaceRow(symbol: "square.grid.2x2", text: "Photo gallery")
                replaceRow(symbol: "sparkles", text: "Icon row")
            }
        }
    }

    private func replaceRow(symbol: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.cucuCardSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.cucuInkRule, lineWidth: 1)
                )

            Text(text)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(Color.cucuInkSoft)

            Spacer()
        }
    }

    // MARK: tip

    private var tipPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("tip · keep the layout, swap the words.")
            Text("it's already cute.")
        }
        .font(.cucuEditorial(17, weight: .regular))
        .italic()
        .foregroundStyle(Color.cucuInkSoft)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.cucuInkRule, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}

// MARK: - JSON decode

/// Same as in `TemplatePickerSheet`, redeclared here as `fileprivate`
/// so the preview view doesn't have to live in the same file. Keeps
/// the dependency direction clean and avoids the picker re-exporting
/// internal helpers.
private func decodeTemplateDocument(_ template: ProfileTemplate) -> ProfileDocument? {
    switch CanvasDocumentCodec.decode(template.templateJSON) {
    case .document(let doc): return doc
    case .legacy, .empty:    return nil
    }
}
