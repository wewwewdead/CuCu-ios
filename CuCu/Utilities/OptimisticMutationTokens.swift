import Foundation

/// Small latest-wins token map for optimistic mutations. A request captures
/// the token returned by `begin`; its completion may mutate UI only when
/// `finish` returns true. Refreshes call `invalidateAll` so older network
/// callbacks cannot roll back newer server snapshots.
nonisolated struct OptimisticMutationTokens: Equatable, Sendable {
    private var tokens: [String: UUID] = [:]

    mutating func begin(for id: String) -> UUID {
        let token = UUID()
        tokens[id] = token
        return token
    }

    func isCurrent(_ token: UUID, for id: String) -> Bool {
        tokens[id] == token
    }

    @discardableResult
    mutating func finish(_ token: UUID, for id: String) -> Bool {
        guard tokens[id] == token else { return false }
        tokens.removeValue(forKey: id)
        return true
    }

    mutating func invalidateAll() {
        tokens.removeAll()
    }
}
