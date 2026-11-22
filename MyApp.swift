import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AccountAppDelegate.self) private var accountDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
