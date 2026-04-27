import SwiftUI

/// Modal font picker for `NodeFontFamily`. Each tile previews the
/// family in its own face — "Aa" centered, the family name in a
/// mono caption underneath — so the user can pick "the one that
/// feels right" without hunting names. Mirrors the mockup's
/// `TextInspector` typeface grid; categories stay as section
/// headers so 17+ faces remain browseable.
struct FontPickerSheet: View {
    @Binding var selection: NodeFontFamily
    /// Fired right after `selection` is updated. Mirrors the
    /// `onCommit(document)` the previous Menu version called so the
    /// SwiftData persist hits the same code path.
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    ForEach(NodeFontFamily.Category.allCases, id: \.self) { category in
                        let families = NodeFontFamily.allCases.filter { $0.category == category }
                        if !families.isEmpty {
                            section(label: category.label, families: families)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
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
    private func section(label: String, families: [NodeFontFamily]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.cucuMono(9, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(families, id: \.self) { family in
                    tile(for: family)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for family: NodeFontFamily) -> some View {
        let isSelected = family == selection
        Button {
            selection = family
            onCommit()
            dismiss()
        } label: {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(family.swiftUIFont(size: 30, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.cucuCard : Color.cucuInk)
                    .lineLimit(1)
                Text(family.displayName.uppercased())
                    .font(.cucuMono(8.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(isSelected ? Color.cucuCard.opacity(0.85) : Color.cucuInkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.cucuInk : Color.cucuCardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.cucuInk : Color.cucuInkRule,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(CucuPressableButtonStyle())
    }
}
