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
    @State private var chrome = AppChromeStore.shared

    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
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
            }
            .cucuRefinedNav("Font")
            .tint(chrome.theme.inkPrimary)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSans(15, weight: .semibold))
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private func section(label: String, families: [NodeFontFamily]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
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
                    .foregroundStyle(isSelected ? chrome.theme.pageColor : chrome.theme.inkPrimary)
                    .lineLimit(1)
                Text(family.displayName)
                    .font(.cucuSans(11, weight: .regular))
                    .foregroundStyle(isSelected ? chrome.theme.pageColor.opacity(0.85) : chrome.theme.inkFaded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? chrome.theme.inkPrimary : tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : chrome.theme.rule,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(CucuPressableButtonStyle())
    }

    private var tileFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
}
