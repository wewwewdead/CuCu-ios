import Foundation
import Observation

/// Observable wrapper around `AuthService` for SwiftUI views.
///
/// Created at app launch and injected via `.environment(_:)`. Tries to load
/// any persisted session in the background but never blocks the UI — the
/// app remains fully usable while this is in flight, including draft editing.
@MainActor
@Observable
final class AuthViewModel {
    private(set) var currentUser: AppUser?
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?
    private(set) var infoMessage: String?

    /// True when Supabase isn't reachable at all (no package or no creds).
    /// Surfaced to the UI as a calm "configure to publish" hint.
    let unavailability: SupabaseClientProvider.Unavailability?

    private let service = AuthService()
    private let usernameService = UsernameService()
    private let roleService = RoleService()

    /// Persisted EULA acceptance flag. Versioned in the key so a
    /// future re-acceptance (e.g. v2 of the policy) can ship without
    /// touching the v1 read path.
    @ObservationIgnored private let eulaKey = "cucu.eula_accepted_v1"
    /// One-time grandfathering flag — flipped on first launch after
    /// Phase 7 ships so the migration only fires once. See
    /// `runEULAMigrationIfNeeded`.
    @ObservationIgnored private let eulaMigrationKey = "cucu.eula_migration_run"
    /// Mirror of UserDefaults so the derived `requiresEULAAcceptance`
    /// surfaces in @Observable change notifications. UserDefaults
    /// itself isn't observable from SwiftUI in this code path; we
    /// shadow the value here and write through.
    private(set) var hasAcceptedEULA: Bool = false

    init() {
        self.unavailability = SupabaseClientProvider.unavailability
        // Pull the persisted EULA flag once at construction so SwiftUI
        // re-renders pick it up without an initial defaults read race.
        self.hasAcceptedEULA = UserDefaults.standard.bool(forKey: "cucu.eula_accepted_v1")
        Task { await loadSession() }
    }

    var isSignedIn: Bool { currentUser != nil }

    /// True once the user is signed in but hasn't claimed a username yet.
    /// Drives the auth gate's transition into `UsernamePickerView` after
    /// sign-up, and the publish sheet's edge-case fallback. Stays false
    /// while signed out so the editor remains usable offline.
    var requiresUsernameClaim: Bool {
        guard let user = currentUser else { return false }
        return (user.username ?? "").isEmpty
    }

    /// True when a signed-in, username-claimed user hasn't yet
    /// agreed to the v1 EULA. Drives the EULA modal in `AuthGateView`
    /// after the username picker. Pre-Phase-7 users are grandfathered
    /// by `runEULAMigrationIfNeeded` so they don't see the modal even
    /// though they've never tapped "I agree".
    var requiresEULAAcceptance: Bool {
        guard let user = currentUser else { return false }
        guard !(user.username ?? "").isEmpty else { return false }
        return !hasAcceptedEULA
    }

    func loadSession() async {
        currentUser = await service.currentUser()
        await hydrateUsername()
        await hydrateRole()
        runEULAMigrationIfNeeded()
    }

    func signIn(email: String, password: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        beginRequest()
        defer { endRequest() }
        do {
            currentUser = try await service.signIn(email: trimmed, password: password)
            await hydrateUsername()
            await hydrateRole()
            runEULAMigrationIfNeeded()
        } catch let err as AuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        beginRequest()
        defer { endRequest() }
        do {
            switch try await service.signUp(email: trimmed, password: password) {
            case .signedIn(let user):
                currentUser = user
                await hydrateUsername()
                await hydrateRole()
                // Brand-new accounts skip the migration write — the
                // EULA flag stays false so they see the modal after
                // claiming a username, which is the intended flow.
            case .needsEmailVerification:
                infoMessage = "Check your email to verify your account, then sign in."
            }
        } catch let err as AuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        beginRequest()
        defer { endRequest() }
        do {
            try await service.signOut()
        } catch {
            // Sign-out failures don't matter to the user — clear local state
            // either way so the app reflects "logged out".
        }
        currentUser = nil
    }

    /// Called by `UsernamePickerView` after a successful claim. Updates
    /// the in-memory `AppUser` so `requiresUsernameClaim` flips to false
    /// without a round-trip — the picker has just written the row, so
    /// re-fetching would only confirm what the caller already knows.
    func setClaimedUsername(_ name: String) {
        guard var user = currentUser else { return }
        user.username = name
        currentUser = user
    }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    /// Pull the user's claimed username from the `usernames` table and
    /// merge it onto `currentUser`. Best-effort: a network failure leaves
    /// `username` as nil, which routes the user into the picker — the
    /// picker's own availability check will surface the real network
    /// error if one persists.
    private func hydrateUsername() async {
        guard let user = currentUser else { return }
        let claimed = await usernameService.fetchUsername(userId: user.id)
        var copy = user
        copy.username = claimed
        currentUser = copy
    }

    /// Pull the user's `user_roles` row and merge `isAdmin` /
    /// `isModerator` flags onto `currentUser`. Soft-fails to "no
    /// role" the same way `hydrateUsername` soft-fails — admin/mod
    /// surfaces stay hidden on a transient lookup failure rather
    /// than over-granting privilege.
    private func hydrateRole() async {
        guard let user = currentUser else { return }
        let role = await roleService.fetchRole(userId: user.id)
        var copy = user
        copy.isAdmin = (role == .admin)
        copy.isModerator = (role == .admin || role == .moderator)
        currentUser = copy
    }

    /// Mark the EULA accepted in both UserDefaults (durable) and the
    /// in-memory mirror (so `requiresEULAAcceptance` flips immediately
    /// without waiting for a UserDefaults observation).
    func acceptEULA() {
        UserDefaults.standard.set(true, forKey: eulaKey)
        hasAcceptedEULA = true
    }

    /// One-time grandfathering for users who signed up before Phase 7
    /// shipped. Strategy: the first time an authenticated, username-
    /// claimed user runs this build, mark the EULA accepted on their
    /// behalf. Brand-new accounts created from this build forward
    /// won't satisfy the "username already claimed at first run"
    /// branch — they'll claim a name *after* this point and so still
    /// see the modal, which is correct.
    ///
    /// Realistically, since CuCu is pre-launch, every existing user
    /// at the time this Phase 7 ships is fine to grandfather — we're
    /// not aware of any historical user who needs to be re-prompted.
    /// The migration is here mainly so the post-launch behavior
    /// (everybody who signs up sees the modal exactly once) is safe.
    private func runEULAMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: eulaMigrationKey) else { return }
        defaults.set(true, forKey: eulaMigrationKey)

        // Nothing to grandfather if there's no signed-in user with a
        // claimed username right now.
        guard let user = currentUser, !(user.username ?? "").isEmpty else { return }
        // Don't stomp an explicit acceptance the user has already
        // recorded (e.g., bouncing between TestFlight builds).
        guard !defaults.bool(forKey: eulaKey) else {
            hasAcceptedEULA = true
            return
        }
        defaults.set(true, forKey: eulaKey)
        hasAcceptedEULA = true
    }

    private func beginRequest() {
        isLoading = true
        errorMessage = nil
        infoMessage = nil
    }

    private func endRequest() {
        isLoading = false
    }
}
