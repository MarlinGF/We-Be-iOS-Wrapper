import SwiftUI
import FirebaseCore

@main
struct We_BeApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationAppDelegate.self) private var appDelegate

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            print("PushDebug: Firebase configured in SwiftUI app init.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
