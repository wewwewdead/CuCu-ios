import SwiftUI

/// "Blocked users" — pushed from `AccountSheet` → Privacy section.
/// Lists every account the signed-in user has blocked, with a
/// per-row Unblock button. Empty state when the list is empty.
///
/// All reads / writes go through `UserBlockService`; RLS gates
/// every query to `auth.uid() = blocker_id` so the view doesn't
/// have to filter client-side.
struct BlockedUsersListView: View {
    @State private var users: [BlockedUser] = []
    @State private var status: Status = .loading
    /// Set of user-ids whose Unblock button is mid-flight. Drives
    /// per-row spinners + disable so a double-tap can't fire two
    /// DELETEs against the same row.
    @State private var unblockingIds: Set<String> = []
    @State private var inlineError: String?

    private enum Status: Equatable {
        case loading
        case loaded
        case empty
        case error(String)
    }

    var body: some View {
        Group {
            switch status {
            case .loading:
                loadingState
            case .empty:
                emptyState
            case .loaded:
                userList
            case .error(let message):
                errorState(message)
            }
        }
        .navigationTitle("Blocked users")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .alert(
            "Couldn't unblock",
            isPresented: Binding(
                get: { inlineError != nil },
                set: { if !$0 { inlineError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { inlineError = nil }
        } message: {
            Text(inlineError ?? "")
        }
    }

    private var userList: some View {
        List {
            ForEach(users) { user in
                row(user)
            }
        }
    }

    private func row(_ user: BlockedUser) -> some View {
        HStack {
            Text(displayHandle(for: user))
                .font(.body.monospaced())
            Spacer()
            if unblockingIds.contains(user.userId) {
                ProgressView().controlSize(.small)
            } else {
                Button("Unblock") {
                    Task { await unblock(user) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func displayHandle(for user: BlockedUser) -> String {
        if let username = user.username, !username.isEmpty {
            return "@\(username)"
        }
        // A blocked account that hasn't claimed a handle yet —
        // surface the truncated id so the row is at least
        // identifiable.
        let suffix = String(user.userId.suffix(6))
        return "user…\(suffix)"
    }

    // MARK: - State surfaces

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No blocked users.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load your blocked list")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Actions

    private func load() async {
        if users.isEmpty { status = .loading }
        do {
            let next = try await UserBlockService().fetchBlockedUsers()
            users = next
            status = next.isEmpty ? .empty : .loaded
        } catch let err as UserBlockError {
            status = .error(err.errorDescription ?? "Couldn't load.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func unblock(_ user: BlockedUser) async {
        unblockingIds.insert(user.userId)
        defer { unblockingIds.remove(user.userId) }
        do {
            try await UserBlockService().unblock(userId: user.userId)
            users.removeAll { $0.userId == user.userId }
            if users.isEmpty { status = .empty }
        } catch let err as UserBlockError {
            inlineError = err.errorDescription ?? "Couldn't unblock right now."
        } catch {
            inlineError = error.localizedDescription
        }
    }
}
