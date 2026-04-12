import Foundation
import UIKit
import UserNotifications
import WebKit

@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private let backendURL = URL(string: "https://webefriends.com/api/push/saveSubscription")!
    private var currentUserId: String?
    fileprivate var currentToken: String?
    private var lastSyncedPair: String?
    private var hasAttemptedPushRegistration = false

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        logAuthorizationStatus()
    }

    func updateCurrentUserId(_ userId: String?) {
        let normalized = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentUserId = (normalized?.isEmpty == false) ? normalized : nil
        print("PushDebug: current user id updated to \(currentUserId ?? "<none>").")

        if currentUserId != nil {
            requestAuthorizationAndRegisterIfNeeded()
        }

        Task {
            await syncIfNeeded()
        }
    }

    func updateAPNsToken(_ deviceToken: Data) {
        currentToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("PushDebug: APNs token captured with prefix \(String(currentToken?.prefix(12) ?? ""))...")
        Task {
            await syncIfNeeded()
        }
    }

    func updateBadgeCount(_ count: Int) {
        let sanitizedCount = max(0, count)
        UIApplication.shared.applicationIconBadgeNumber = sanitizedCount
        print("PushDebug: native badge count updated to \(sanitizedCount).")
    }

    fileprivate func syncIfNeeded() async {
        guard let userId = currentUserId, let token = currentToken else {
            print("PushDebug: sync skipped; userId=\(currentUserId ?? "<none>") tokenPresent=\(currentToken != nil).")
            return
        }

        let pair = "\(userId)::\(token)"
        if lastSyncedPair == pair {
            print("PushDebug: sync skipped; token already stored for \(userId).")
            return
        }

        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userId,
            "tokenType": "apns",
            "token": token,
            "environment": currentPushEnvironment,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("APNs token sync failed: missing HTTP response.")
                return
            }

            let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            guard (200...299).contains(httpResponse.statusCode) else {
                print("APNs token sync failed with status \(httpResponse.statusCode): \(responseBody)")
                return
            }

            lastSyncedPair = pair
            print("APNs token synced for user \(userId). Response: \(responseBody)")
        } catch {
            print("APNs token sync failed: \(error.localizedDescription)")
        }
    }

    private func logAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("PushDebug: authorization status is \(settings.authorizationStatus.rawValue); badges=\(settings.badgeSetting.rawValue) alerts=\(settings.alertSetting.rawValue) sounds=\(settings.soundSetting.rawValue).")
        }
    }

    private func requestAuthorizationAndRegisterIfNeeded() {
        guard !hasAttemptedPushRegistration else {
            print("PushDebug: push registration already attempted for this launch.")
            return
        }

        hasAttemptedPushRegistration = true
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    print("PushDebug: notifications already authorized. Registering for remote notifications.")
                    UIApplication.shared.registerForRemoteNotifications()
                }
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        print("Push authorization failed: \(error.localizedDescription)")
                        return
                    }

                    DispatchQueue.main.async {
                        print("PushDebug: authorization prompt result granted=\(granted). Registering for remote notifications.")
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            case .denied:
                print("Push authorization not granted.")
            @unknown default:
                print("PushDebug: unknown notification authorization status \(settings.authorizationStatus.rawValue).")
            }
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
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("=== APNs TOKEN RECEIVED === \(token)")
        Task { @MainActor in
            PushNotificationManager.shared.updateAPNsToken(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("=== APNs REGISTRATION FAILED === \(error.localizedDescription)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        print("=== App became active - checking push registration ===")
        PushNotificationManager.shared.configure()
    }
}

private var currentPushEnvironment: String {
#if DEBUG
    return "development"
#else
    return "production"
#endif
}

enum WebAuthBridgeScript {
    static let handlerName = "webeAuthState"

    static let source = """
    (function() {
        const handlerName = '\(handlerName)';
        let lastUid = null;

        function log(message) {
            try {
                console.log('[We-Be iOS bridge]', message);
            } catch (error) {
            }
        }

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
                        log('found uid in localStorage');
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
            log(uid ? 'publishing uid to native bridge' : 'publishing signed-out state to native bridge');
            try {
                window.webkit.messageHandlers[handlerName].postMessage(uid);
            } catch (error) {
                console.log('We-Be iOS auth bridge post error', error);
            }
        }

        const originalSetItem = localStorage.setItem.bind(localStorage);
        localStorage.setItem = function(key, value) {
            originalSetItem(key, value);
            if (typeof key === 'string' && key.startsWith('firebase:authUser:')) {
                publish();
            }
        };

        const originalRemoveItem = localStorage.removeItem.bind(localStorage);
        localStorage.removeItem = function(key) {
            originalRemoveItem(key);
            if (typeof key === 'string' && key.startsWith('firebase:authUser:')) {
                publish();
            }
        };

        publish();
        window.addEventListener('load', publish);
        window.addEventListener('focus', publish);
        window.addEventListener('pageshow', publish);
        window.addEventListener('storage', publish);
        document.addEventListener('visibilitychange', publish);
        setInterval(publish, 2000);
    })();
    """
}

enum WebBadgeBridgeScript {
    static let handlerName = "webeBadgeCount"
}

final class WebAuthScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebAuthBridgeScript.handlerName else {
            return
        }

        let uid = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        print("PushDebug: web auth bridge delivered uid \(uid?.isEmpty == false ? uid! : "<none>").")
        Task { @MainActor in
            PushNotificationManager.shared.updateCurrentUserId(uid)
        }
    }
}

final class WebBadgeScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebBadgeBridgeScript.handlerName else {
            return
        }

        let badgeValue: Int
        if let number = message.body as? NSNumber {
            badgeValue = number.intValue
        } else if let stringValue = message.body as? String, let parsed = Int(stringValue) {
            badgeValue = parsed
        } else {
            print("PushDebug: ignored invalid badge payload \(message.body).")
            return
        }

        Task { @MainActor in
            PushNotificationManager.shared.updateBadgeCount(badgeValue)
        }
    }
}
