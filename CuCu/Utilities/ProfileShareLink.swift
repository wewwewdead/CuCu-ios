import Foundation

/// Central place for public-profile link formatting.
/// This phase intentionally shares only the in-app public path (`/@username`).
nonisolated enum ProfileShareLink {
    static func normalizedUsername(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@")
            .lowercased()
    }

    static func path(username raw: String) -> String {
        "/@\(normalizedUsername(raw))"
    }

    static func linkString(username raw: String) -> String {
        path(username: raw)
    }

    static func activityItem(username raw: String) -> Any {
        path(username: raw)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
