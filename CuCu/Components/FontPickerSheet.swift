import SwiftUI

/// Modal font picker for `NodeFontFamily`. Replaces the inline `Menu`
/// approach (which became a 17-row scroll once the cute / artsy faces
/// landed) with a sectioned list where each row previews the font in
/// the actual face — far easier to pick "the one that feels right"
/// when names alone don't tell the user what Caprasimo vs Yeseva One
/// vs Lobster will look like on their canvas.
///
/// Sections come from `NodeFontFamily.Category` so future faces drop
/// into the right group automatically by tagging their `.category`.
struct FontPickerSheet: View {
    @Binding var selection: NodeFontFamily
    /// Fired right after `selection` is updated. Mirrors the
    /// `onCommit(document)` the previous Menu version called so the
    /// SwiftData persist hits the same code path.
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(NodeFontFamily.Category.allCases, id: \.self) { category in
                    Section {
                        ForEach(NodeFontFamily.allCases.filter { $0.category == category }, id: \.self) { family in
                            row(for: family)
                        }
                    } header: {
                        Text(category.label)
                            .font(.cucuSerif(13, weight: .bold))
                            .foregroundStyle(Color.cucuInk)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.cucuPaper.ignoresSafeArea())
            .cucuSheetTitle("Font")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .tint(Color.cucuInk)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSerif(16, weight: .bold))
                }
            }
        }
    }

    @ViewBuilder
    private func row(for family: NodeFontFamily) -> some View {
        let isSelected = family == selection
        Button {
            selection = family
            onCommit()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                // Live preview: the family's own name rendered in its
                // own font. Two-tier sample — "Aa" big + the family
                // name smaller — covers both letterform identity and
                // glyph variety in one row.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aa")
                        .font(family.swiftUIFont(size: 26, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Text(family.displayName)
                        .font(family.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(Color.cucuInkSoft)
                        .lineLimit(1)
                }
                .frame(width: 116, alignment: .leading)

                // Display name in the *current* design system font
                // (Lexend) so the user can read it consistently
                // even if the previewed face is hard to scan in
                // small UI sizes (e.g. Press Start 2P, Modak).
                Text(family.displayName)
                    .font(.cucuSans(15, weight: .medium))
                    .foregroundStyle(Color.cucuInk)
                    .lineLimit(1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Color.cucuBurgundy)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.cucuRose.opacity(0.4) : Color.cucuCard)
    }
}
