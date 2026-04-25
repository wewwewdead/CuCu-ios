import SwiftUI
import SwiftData

@main
struct CreativeProfileApp: App {
    /// Auth lives at the app root so any screen can read the current session.
    /// It loads in the background and never blocks rendering — the offline
    /// builder is fully usable while this hydrates (or fails) silently.
    @State private var authViewModel = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authViewModel)
        }
        .modelContainer(for: ProfileDraft.self)
    }
}
