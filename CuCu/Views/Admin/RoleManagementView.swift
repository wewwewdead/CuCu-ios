import SwiftUI

/// Role management — pushed from `AccountSheet` for admins only.
/// Reads `user_roles` joined to `usernames` and lets the admin
/// grant moderator status by handle, or revoke an existing role
/// by tapping its row.
///
/// One foot-gun the UI guards against: an admin revoking their
/// **own** admin row would lock themselves out of the screen with
/// no in-app path back. The button stays disabled for that row;
/// SQL editor remains the authoritative path for "remove the
/// bootstrap admin", which is the right hatch for a high-blast
/// action.
struct RoleManagementView: View {
    @Environment(AuthViewModel.self) private var auth

    @State private var assignments: [RoleAssignment] = []
    @State private var status: Status = .loading
    @State private var grantInput: String = ""
    @State private var isGranting: Bool = false
    @State private var inFlightRevokes: Set<String> = []
    @State private var inlineError: String?
    @State private var toastMessage: String? = nil

    private enum Status: Equatable {
        case loading
        case loaded
        case empty
        case error(String)
    }

    var body: some View {
        Form {
            grantSection
            existingSection
        }
        .navigationTitle("Manage roles")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .cucuToast(message: $toastMessage)
        .alert(
            "Couldn't update role",
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

    // MARK: - Grant

    private var grantSection: some View {
        Section {
            HStack(spacing: 6) {
                Text("@")
                    .foregroundStyle(.secondary)
                    .font(.body.monospaced())
                TextField("username", text: $grantInput)
                    .font(.body.monospaced())
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isGranting)
            }
            Button {
                Task { await grantModerator() }
            } label: {
                HStack {
                    Spacer()
                    if isGranting {
                        ProgressView()
                    } else {
                        Text("Grant moderator").fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(grantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGranting)
        } header: {
            Text("Grant moderator")
        } footer: {
            Text("Give an existing user moderator privileges. Bootstrap admins are added via SQL.")
        }
    }

    // MARK: - Existing list

    @ViewBuilder
    private var existingSection: some View {
        Section {
            switch status {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
            case .empty:
                Text("No moderators or admins yet.")
                    .foregroundStyle(.secondary)
            case .loaded:
                ForEach(assignments) { assignment in
                    row(assignment)
                }
            case .error(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load roles")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await load() }
                    }
                }
            }
        } header: {
            Text("Current admins & moderators")
        }
    }

    private func row(_ assignment: RoleAssignment) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayHandle(for: assignment))
                    .font(.body.monospaced())
                Text(assignment.role == .admin ? "Admin" : "Moderator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if inFlightRevokes.contains(assignment.userId) {
                ProgressView().controlSize(.small)
            } else {
                Button("Revoke", role: .destructive) {
                    Task { await revoke(assignment) }
                }
                .buttonStyle(.bordered)
                .disabled(isOwnRow(assignment))
            }
        }
    }

    private func displayHandle(for assignment: RoleAssignment) -> String {
        if let username = assignment.username, !username.isEmpty {
            return "@\(username)"
        }
        let suffix = String(assignment.userId.suffix(6))
        return "user…\(suffix)"
    }

    /// True when the assignment is the signed-in admin's own row.
    /// We disable the Revoke button on this row so the admin
    /// can't lock themselves out of the screen mid-tap.
    private func isOwnRow(_ assignment: RoleAssignment) -> Bool {
        guard let me = auth.currentUser?.id.lowercased() else { return false }
        return assignment.userId.lowercased() == me
    }

    // MARK: - Actions

    private func load() async {
        if assignments.isEmpty { status = .loading }
        do {
            let next = try await RoleService().fetchModeratorsAndAdmins()
            assignments = next
            status = next.isEmpty ? .empty : .loaded
        } catch let err as RoleError {
            status = .error(err.errorDescription ?? "Couldn't load roles.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func grantModerator() async {
        let trimmed = grantInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return }
        isGranting = true
        defer { isGranting = false }
        do {
            _ = try await RoleService().grantModerator(username: trimmed)
            grantInput = ""
            toastMessage = "Granted moderator to @\(trimmed)"
            await load()
        } catch let err as RoleError {
            inlineError = err.errorDescription ?? "Couldn't grant role."
        } catch {
            inlineError = error.localizedDescription
        }
    }

    private func revoke(_ assignment: RoleAssignment) async {
        guard !isOwnRow(assignment) else { return }
        inFlightRevokes.insert(assignment.userId)
        defer { inFlightRevokes.remove(assignment.userId) }
        do {
            try await RoleService().revokeRole(userId: assignment.userId)
            assignments.removeAll { $0.userId == assignment.userId }
            if assignments.isEmpty { status = .empty }
            toastMessage = "Revoked"
        } catch let err as RoleError {
            inlineError = err.errorDescription ?? "Couldn't revoke role."
        } catch {
            inlineError = error.localizedDescription
        }
    }
}
