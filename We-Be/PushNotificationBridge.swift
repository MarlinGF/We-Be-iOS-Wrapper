import Foundation
import UIKit
import UserNotifications
import FirebaseMessaging
import WebKit

@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private let backendURL = URL(string: "https://webefriends.com/api/push/saveSubscription")!
    private var currentUserId: String?
    fileprivate var currentToken: String?
    private var lastSyncedPair: String?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        requestAuthorizationAndRegister()
        refreshFCMToken()
    }

    func updateCurrentUserId(_ userId: String?) {
        let normalized = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentUserId = (normalized?.isEmpty == false) ? normalized : nil

        Task {
            await syncIfNeeded()
        }
    }

    func updateAPNsToken(_ deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        refreshFCMToken()
    }

    fileprivate func syncIfNeeded() async {
        guard let userId = currentUserId, let token = currentToken else {
            return
        }

        let pair = "\(userId)::\(token)"
        if lastSyncedPair == pair {
            return
        }

        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "tokenType": "fcm",
            "token": token,
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                print("FCM token sync failed with non-success response.")
                return
            }

            lastSyncedPair = pair
            print("FCM token synced for user \(userId).")
        } catch {
            print("FCM token sync failed: \(error.localizedDescription)")
        }
    }

    private func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                print("Push authorization failed: \(error.localizedDescription)")
                return
            }

            guard granted else {
                print("Push authorization not granted.")
                return
            }

            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func refreshFCMToken() {
        Messaging.messaging().token { [weak self] token, error in
            if let error {
                print("FCM token fetch failed: \(error.localizedDescription)")
                return
            }

            guard let self, let token, !token.isEmpty else {
                return
            }

            Task { @MainActor in
                self.currentToken = token
                await self.syncIfNeeded()
            }
        }
    }
}

extension PushNotificationManager: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else {
            return
        }

        Task { @MainActor in
            PushNotificationManager.shared.currentToken = fcmToken
            await PushNotificationManager.shared.syncIfNeeded()
        }
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound, .list])
    }
}

final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushNotificationManager.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.updateAPNsToken(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}

enum WebAuthBridgeScript {
    static let handlerName = "webeAuthState"

    static let source = """
    (function() {
        const handlerName = '\(handlerName)';
        let lastUid = null;

        function currentUid() {
            try {
                for (let index = 0; index < localStorage.length; index += 1) {
                    const key = localStorage.key(index);
                    if (!key || !key.startsWith('firebase:authUser:')) {
                        continue;
                    }

                    const raw = localStorage.getItem(key);
                    if (!raw) {
                        continue;
                    }

                    const parsed = JSON.parse(raw);
                    if (parsed && typeof parsed.uid === 'string' && parsed.uid.length > 0) {
                        return parsed.uid;
                    }
                }
            } catch (error) {
                console.log('We-Be iOS auth bridge error', error);
            }

            return '';
        }

        function publish() {
            const uid = currentUid();
            if (uid === lastUid) {
                return;
            }

            lastUid = uid;
            try {
                window.webkit.messageHandlers[handlerName].postMessage(uid);
            } catch (error) {
                console.log('We-Be iOS auth bridge post error', error);
            }
        }

        publish();
        window.addEventListener('focus', publish);
        window.addEventListener('pageshow', publish);
        document.addEventListener('visibilitychange', publish);
        setInterval(publish, 2000);
    })();
    """
}

final class WebAuthScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebAuthBridgeScript.handlerName else {
            return
        }

        let uid = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            PushNotificationManager.shared.updateCurrentUserId(uid)
        }
    }
}
