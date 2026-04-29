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
            .background(Color.cucuPaper.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .cucuSheetTitle("Icon")
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
                    .foregroundStyle(isSelected ? Color.cucuBurgundy : Color.cucuInk)
                    .frame(width: 50, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? Color.cucuRose : Color.cucuCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.cucuBurgundy : Color.cucuInk.opacity(0.20),
                                          lineWidth: isSelected ? 1.5 : 1)
                    )
                Text(IconCatalog.label(for: name))
                    .font(.cucuSans(10, weight: .medium))
                    .foregroundStyle(Color.cucuInkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.cucuInkFaded)
            Text("No icons match \"\(query)\"")
                .font(.cucuSans(13, weight: .medium))
                .foregroundStyle(Color.cucuInkFaded)
        }
        .frame(maxWidth: .infinity)
    }
}
