import SwiftUI

@main
struct VoiceOrbPlaygroundApp: App {
    var body: some Scene {
        WindowGroup {
            OrbTestScreen()
                // The orb canvas uses a fixed light background in every material.
                .preferredColorScheme(.light)
        }
    }
}
