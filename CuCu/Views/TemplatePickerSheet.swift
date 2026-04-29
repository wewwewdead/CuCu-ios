import SwiftData
import SwiftUI

// MARK: - Template picker sheet
//
// Visual replacement for the older list-style `ApplyTemplateSheet`.
// Mirrors the prototype's `TemplatesPicker` (`templates-picker.jsx`):
// header with eyebrow + italic title + instruction copy, a grid of
// cards each showing a mini-iPhone preview rendered from the template's
// own `ProfileDocument`, four-dot palette swatch, name + vibe, and
// per-card Preview / Use-this buttons. Tapping a card or "Use this"
// confirms via alert then fires `onApply`.
//
// Callback contract matches `ApplyTemplateSheet`: returning `true`
// dismisses the sheet, `false` keeps it open and surfaces an error
// message.

struct TemplatePickerSheet: View {
    /// Sorted by `updatedAt` so newly-saved user templates float to the
    /// top, but we re-order in `body` to put seeded defaults first
    /// (that's where the visual showcase lives).
    @Query(sort: \ProfileTemplate.updatedAt, order: .reverse) private var templates: [ProfileTemplate]

    var onApply: (ProfileTemplate) -> Bool

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cucuWidthClass) private var widthClass

    @State private var pendingTemplate: ProfileTemplate?
    @State private var previewTemplate: ProfileTemplate?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.cucuInkRule)
            grid
        }
        .background(Color.cucuPaper.ignoresSafeArea())
        // Sheets present in their own scene context — re-measure here
        // so children can read the picker's actual width (iPhone full-
        // screen vs iPad form-sheet) instead of the underlying app.
        .cucuWidthClass()
        .alert(
            "Replace current canvas?",
            isPresented: confirmationPresented,
            actions: {
                Button("Cancel", role: .cancel) { pendingTemplate = nil }
                Button("Apply", role: .destructive) { applyPendingTemplate() }
            },
            message: {
                Text("This replaces the current canvas design. The draft title stays the same.")
            }
        )
        .fullScreenCover(item: $previewTemplate) { template in
            TemplateFullscreenPreview(
                template: template,
                onApply: { applied in
                    // Preview ran the confirmation alert + apply
                    // itself; if it succeeded we also dismiss the
                    // picker so the user lands back on the canvas.
                    let success = onApply(applied)
                    if success { dismiss() }
                    return success
                }
            )
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            // Conic-gradient logo swatch (matches prototype's swirl
            // square at the top-left of the picker).
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AngularGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "#FFE5EE"), Color(hex: "#FBF8F2"),
                        Color(hex: "#0E0A14"), Color(hex: "#F2EEE3"),
                        Color(hex: "#1B1B66"), Color(hex: "#FFE5EE"),
                    ]),
                    center: .center
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cucuInk, lineWidth: 1.5)
                )
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("TEMPLATES")
                    .font(.cucuMono(9.5, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Color.cucuInkFaded)
                Text("start from a template")
                    .font(.cucuEditorial(22, weight: .semibold))
                    .italic()
                    .foregroundStyle(Color.cucuInk)
            }

            Spacer(minLength: 14)

            // Instruction copy is the first thing users glance at when
            // the picker opens — but on iPhone SE / iPhone 15 the old
            // fixed `.frame(maxWidth: 320)` competed with the title
            // for space and forced ugly mid-word breaks. On compact
            // (SE) we hide it entirely (the picker is mostly self-
            // explanatory once cards are visible); on regular and up
            // we let it wrap naturally with a soft cap that scales
            // with the width class so it doesn't dominate on iPad.
            if widthClass != .compact {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("pick a vibe, fill in your name & links, you're done.")
                        .font(.cucuSans(12.5, weight: .regular))
                        .foregroundStyle(Color.cucuInkSoft)
                    if widthClass.isAtLeastExpanded {
                        Text("everything stays editable after.")
                            .font(.cucuSans(12.5, weight: .regular))
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                }
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .layoutPriority(0)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.cucuCardSoft)
                    )
                    .overlay(
                        Circle().strokeBorder(Color.cucuInkRule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CucuSpacing.screenInset(widthClass))
        .padding(.vertical, 18)
        .background(Color.cucuCard)
    }

    // MARK: grid

    private var grid: some View {
        ScrollView {
            if templates.isEmpty {
                emptyState
            } else {
                // Grid spacing + outer padding scale with the width
                // class. The `.adaptive(minimum:)` GridItem
                // automatically lays out 1 column on phones (cards
                // hit ~280pt) and 2-3 on iPad — no manual column
                // math needed; we just nudge the minimum slightly
                // smaller on iPad so cards don't have to be huge to
                // unlock a third column.
                let cardMin: CGFloat = widthClass == .iPad ? 260 : 280
                let gridGap = CucuSpacing.gap(widthClass)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: cardMin), spacing: gridGap)],
                    alignment: .leading,
                    spacing: gridGap
                ) {
                    ForEach(orderedTemplates) { template in
                        TemplatePickerCard(
                            template: template,
                            onPreview: { previewTemplate = template },
                            onUse:     { pendingTemplate = template }
                        )
                    }
                }
                .padding(CucuSpacing.screenInset(widthClass))
                // Cap content width on iPad so the grid doesn't
                // sprawl edge-to-edge on a 12.9" screen — keeps
                // cards readable and centered like a focused
                // browsing surface.
                .frame(maxWidth: widthClass == .iPad ? CucuLayoutCap.modalContent : .infinity)
                .frame(maxWidth: .infinity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.cucuSans(12, weight: .medium))
                    .foregroundStyle(Color.cucuCherry)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cucuPaper)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text("No Templates")
                .font(.cucuEditorial(20, weight: .semibold))
                .italic()
                .foregroundStyle(Color.cucuInk)
            Text("Save a canvas as a template, or relaunch to seed the defaults.")
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: ordering & flow

    /// Seeded defaults first (in `DefaultTemplates.all` order), then any
    /// user-saved templates by `updatedAt`. Lookup is O(n*m) but n=7
    /// and m is small in practice, so the simple version reads cleaner
    /// than building a hash set.
    private var orderedTemplates: [ProfileTemplate] {
        let defaultIDs = DefaultTemplates.all.map(\.id)
        var sortedDefaults: [ProfileTemplate] = []
        for id in defaultIDs {
            if let match = templates.first(where: { $0.id == id }) {
                sortedDefaults.append(match)
            }
        }
        let saved = templates.filter { template in
            !defaultIDs.contains(template.id)
        }
        return sortedDefaults + saved
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingTemplate != nil },
            set: { isPresented in
                if !isPresented { pendingTemplate = nil }
            }
        )
    }

    private func applyPendingTemplate() {
        guard let template = pendingTemplate else { return }
        pendingTemplate = nil
        errorMessage = nil
        if onApply(template) {
            dismiss()
        } else {
            errorMessage = "Couldn't apply that template."
        }
    }
}

// MARK: - Card

/// One template card — mini iPhone preview, palette swatches, name +
/// vibe, action buttons. The whole card is tappable; the buttons sit on
/// top with their own tap targets and `.stopPropagation`-equivalent
/// (`buttonStyle(.plain)` + their own action closure).
private struct TemplatePickerCard: View {
    let template: ProfileTemplate
    /// Tapping the card surface or the "Preview" button: opens the
    /// fullscreen preview overlay (read-only larger view of the same
    /// template).
    let onPreview: () -> Void
    /// Tapping the "Use this" button: triggers the picker's
    /// confirmation alert and applies the template on confirm.
    let onUse: () -> Void

    var body: some View {
        let spec = DefaultTemplates.spec(for: template.id)
        let document = decodeTemplateDocument(template)

        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 10) {
                preview(document: document)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 6) {
                    if let spec {
                        ForEach(Array(spec.swatch.enumerated()), id: \.offset) { _, hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .overlay(Circle().strokeBorder(Color.cucuInkRule, lineWidth: 1))
                                .frame(width: 11, height: 11)
                        }
                    }
                    Spacer()
                    Text(indexLabel)
                        .font(.cucuMono(8.5, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.cucuInkFaded)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.cucuEditorial(18, weight: .semibold))
                        .italic()
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Text(spec?.vibe ?? template.previewSummary ?? "Saved design")
                        .font(.cucuSans(11.5, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    cardButton(label: "Preview", filled: false, action: onPreview)
                    cardButton(label: "Use this", filled: true, action: onUse)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cucuCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cucuInkRule, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func preview(document: ProfileDocument?) -> some View {
        let scale: CGFloat = 0.62
        let pageWidth: CGFloat = CGFloat(document?.pageWidth ?? 390)
        let pageHeight: CGFloat = CGFloat(document?.pages.first?.height ?? document?.pageHeight ?? 805)

        MiniDeviceFrame {
            if let document {
                TplCanvasView(document: document, scale: scale)
            } else {
                Color.cucuPaperDeep
            }
        }
        .frame(width: pageWidth * scale + 12,
               height: pageHeight * scale + 12)
    }

    @ViewBuilder
    private func cardButton(label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.cucuSans(12.5, weight: .semibold))
                .foregroundStyle(filled ? Color.cucuCard : Color.cucuInk)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(filled ? Color.cucuInk : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(filled ? Color.clear : Color.cucuInkRule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var indexLabel: String {
        if let idx = DefaultTemplates.all.firstIndex(where: { $0.id == template.id }) {
            return String(format: "0%d", idx + 1)
        }
        return "—"
    }
}

// MARK: - JSON decode helper

/// Decode a `ProfileTemplate.templateJSON` into a `ProfileDocument` for
/// rendering in the picker preview. Returns `nil` if decode fails so
/// the card can show a placeholder rather than crashing.
private func decodeTemplateDocument(_ template: ProfileTemplate) -> ProfileDocument? {
    switch CanvasDocumentCodec.decode(template.templateJSON) {
    case .document(let doc): return doc
    case .legacy, .empty:    return nil
    }
}
