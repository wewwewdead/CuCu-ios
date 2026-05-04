import SwiftUI
import SwiftData

@main
struct CreativeProfileApp: App {
    /// Auth lives at the app root so any screen can read the current session.
    /// It loads in the background and never blocks rendering — the offline
    /// builder is fully usable while this hydrates (or fails) silently.
    @State private var authViewModel = AuthViewModel()

    /// Coordinator for the post-submission flight animation. Lives at
    /// the app root so the overlay (mounted inside `RootView`) and
    /// the compose sheet / feed (mounted further down the tree) all
    /// read the same instance — phase transitions stay coherent
    /// across the sheet's dismissal.
    @State private var postFlightCoordinator = CucuPostFlightCoordinator()

    init() {
        // Register the bundled Lexend faces before any view tries to look
        // them up via `Font.custom("Lexend-…")`. Failure to register simply
        // falls back to the system font.
        CucuFontRegistration.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authViewModel)
                .environment(postFlightCoordinator)
        }
        .modelContainer(for: [ProfileDraft.self, ProfileTemplate.self])
    }
}
