import SwiftUI
import FirebaseCore

@main
struct We_BeApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
