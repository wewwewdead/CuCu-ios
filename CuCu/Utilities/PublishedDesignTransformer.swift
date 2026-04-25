import Foundation

/// Pure transformer from a *local* ProfileDesign to its *published* twin.
///
/// The published design has the same shape — same Codable schema — but every
/// `localImagePath` and `theme.backgroundImagePath` is replaced with the
/// corresponding remote URL (or storage path). The local source is never
/// mutated; the local draft keeps using local relative paths so the iOS
/// builder continues to render offline.
///
/// `pathMap` is keyed by the *local* relative path and yields the public URL
/// or storage path to substitute. The PublishService builds it after each
/// asset upload completes.
///
/// Containers are walked recursively so nested image blocks at any depth
/// have their paths swapped.
enum PublishedDesignTransformer {
    static func transform(
        _ source: ProfileDesign,
        replacing pathMap: [String: String]
    ) -> ProfileDesign {
        var copy = source

        if let local = copy.theme.backgroundImagePath, let remote = pathMap[local] {
            copy.theme.backgroundImagePath = remote
        }

        copy.blocks = copy.blocks.map { transformBlock($0, pathMap: pathMap) }
        return copy
    }

    private static func transformBlock(
        _ block: ProfileBlock,
        pathMap: [String: String]
    ) -> ProfileBlock {
        switch block {
        case .text:
            return block
        case .image(var data):
            if let remote = pathMap[data.localImagePath] {
                data.localImagePath = remote
            }
            return .image(data)
        case .container(var data):
            data.children = data.children.map { transformBlock($0, pathMap: pathMap) }
            return .container(data)
        }
    }
}
