import SwiftUI

/// Shared shell for every per-node bottom inspector — header row
/// (Duplicate · Delete · id chip · Close) + centered dark-capsule
/// TabBar + content slot. Pulled out as its own view so the text /
/// image / icon / divider / link / gallery / carousel / container
/// inspectors all read with one visual treatment.
///
/// The chrome is "dumb": it owns no node state and forwards every
/// affordance through the closures the host provides. The active
/// tab is also host-driven so a host that only needs one tab can
/// pin `selectedIndex` to 0 and skip rendering the tab bar by
/// passing fewer than two tabs.
struct ElementInspectorChrome<Content: View>: View {
    /// Mono-caps badge in the header. Caller picks the casing —
    /// "TEXT", "IMAGE", "GALLERY", etc.
    let typeLabel: String
    /// Six-char identifier shown after the type label so multiple
    /// inspectors of the same type stay distinguishable.
    let idTag: String
    /// Tab labels (already in display case). Pass two or more to
    /// surface the dark capsule TabBar; pass one (or none) and the
    /// bar is hidden.
    let tabs: [String]
    @Binding var selectedIndex: Int
    var onDuplicate: () -> Void
    var canDuplicate: Bool = true
    var onDelete: () -> Void
    var canDelete: Bool = true
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            if tabs.count > 1 { tabBar }
            content()
        }
        .background(Color.cucuCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cucuInk.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cucuCard)
                    .frame(width: 36, height: 32)
                    .background(Capsule(style: .continuous).fill(Color.cucuInk))
                    .opacity(canDuplicate ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canDuplicate)
            .accessibilityLabel("Duplicate")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 36, height: 32)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(Color.cucuInk.opacity(0.18), lineWidth: 1)
                    )
                    .opacity(canDelete ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .accessibilityLabel("Delete")

            Spacer(minLength: 0)

            Text("\(typeLabel) · \(idTag)")
                .font(.cucuMono(9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.cucuInk.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.cucuInk.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: TabBar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, label in
                tabButton(index: index, label: label)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.cucuInk))
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(index: Int, label: String) -> some View {
        let active = selectedIndex == index
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedIndex = index
            }
        } label: {
            Text(label)
                .font(.cucuSans(13, weight: .semibold))
                .foregroundStyle(active ? Color.cucuInk : Color.cucuCard)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule(style: .continuous)
                        .fill(active ? Color.cucuCard : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Type-label helpers

extension ElementInspectorChrome {
    /// Mono-caps wordmark for a node — used in the header pill.
    /// Centralized here so every inspector picks the same casing
    /// without each one re-deriving it from `node.type`.
    static func typeLabel(for node: CanvasNode) -> String {
        if let role = node.role {
            switch role {
            case .profileHero:   return "HEADER"
            case .profileAvatar: return "AVATAR"
            case .profileName:   return "NAME"
            case .profileBio:    return "BIO"
            case .profileMeta:   return "META"
            case .fixedDivider:  return "SPACER"
            case .sectionCard:   return "SECTION"
            }
        }
        switch node.type {
        case .container: return "SECTION"
        case .text:      return "TEXT"
        case .image:     return "IMAGE"
        case .icon:      return "ICON"
        case .divider:   return "DIVIDER"
        case .link:      return "LINK"
        case .gallery:   return "GALLERY"
        case .carousel:  return "CAROUSEL"
        }
    }

    /// First-tab display name — what shows up as the leftmost capsule
    /// label in the TabBar. Mirrors the existing `NodeEditingPanelView`
    /// `label(for:on:)` so users see the same word as the legacy
    /// segmented picker on first open.
    static func contentTabLabel(for node: CanvasNode) -> String {
        switch node.type {
        case .image:    return "Image"
        case .gallery:  return "Photos"
        case .carousel: return "Items"
        default:        return "Edit"
        }
    }

    /// Six-char id suffix for the header's mono-caps chip.
    static func idTag(for id: UUID) -> String {
        let raw = id.uuidString.replacingOccurrences(of: "-", with: "")
        return String(raw.prefix(6))
    }
}
