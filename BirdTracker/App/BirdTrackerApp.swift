import SwiftUI

@main
struct BirdTrackerApp: App {
    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
