import SwiftUI

/// Modal grid picker for the SF Symbol catalog. Surfaces every icon
/// from `IconCatalog.starter` as a tappable tile so users can scan
/// the full set at once instead of scrolling a 90-row menu.
///
/// Selection commits as soon as a tile is tapped — the host's
/// `onCommit` callback runs (mirrors what the inline `Menu` did
/// before) and the sheet dismisses. The grid is `LazyVGrid` so
/// off-screen tiles don't pay rendering cost up front.
struct IconPickerSheet: View {
    @Binding var selection: String
    /// Fired right after `selection` is updated. Lets the inspector
    /// run its existing `onCommit(document)` so the SwiftData
    /// persist hits the same code path the Menu version triggered.
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chrome = AppChromeStore.shared
    @State private var query: String = ""

    /// 5-column grid on iPhone reads as a comfortable browse — wide
    /// enough that each tile shows the symbol clearly, narrow enough
    /// that the user can see ~25 icons per scroll position.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
        count: 5
    )

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return IconCatalog.starter }
        return IconCatalog.starter.filter { name in
            name.contains(trimmed)
                || IconCatalog.label(for: name).lowercased().contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                ScrollView {
                    if filtered.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered, id: \.self) { name in
                                tile(for: name)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .cucuRefinedNav("Icon")
            .tint(chrome.theme.inkPrimary)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSans(15, weight: .semibold))
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search icons")
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(for name: String) -> some View {
        let isSelected = selection == name
        Button {
            selection = name
            onCommit()
            dismiss()
        } label: {
            VStack(spacing: 4) {
                glyph(for: name)
                    .foregroundStyle(isSelected ? chrome.theme.pageColor : chrome.theme.inkPrimary)
                    .frame(width: 50, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? chrome.theme.inkPrimary : tileFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.clear : chrome.theme.rule, lineWidth: 1)
                    )
                Text(IconCatalog.label(for: name))
                    .font(.cucuSans(10, weight: .medium))
                    .foregroundStyle(chrome.theme.inkFaded)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private var tileFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    /// Mirrors `IconNodeView`'s three-way fork so the picker preview
    /// matches what lands on the canvas:
    ///   • `brand.*` → vendored single-color SVG, template-tinted.
    ///   • `multi.*` → vendored multi-color SVG, original colors.
    ///   • everything else → SF Symbol.
    @ViewBuilder
    private func glyph(for name: String) -> some View {
        if name.hasPrefix("brand.") {
            let assetName = "SocialIcons/" + String(name.dropFirst("brand.".count))
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(12)
        } else if name.hasPrefix("multi.") {
            let assetName = "Glyphs/" + String(name.dropFirst("multi.".count))
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .padding(10)
        } else {
            Image(systemName: name)
                .font(.system(size: 22, weight: .semibold))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No icons match \"\(query)\"")
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
        }
        .frame(maxWidth: .infinity)
    }
}
