import SwiftUI
import WebKit
import Network
import Combine
import AVFoundation

final class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    @Published var isOnline: Bool = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }
}

final class WebViewStore: ObservableObject {
    let webView: WKWebView

    init(url: URL) {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        let platformScript = WKUserScript(
            source: """
            (function() {
                function markIOS() {
                    document.documentElement.setAttribute('data-platform', 'ios');
                    if (document.body) {
                        document.body.setAttribute('data-platform', 'ios');
                    }
                }
                markIOS();
                document.addEventListener('DOMContentLoaded', markIOS, { once: true });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        contentController.addUserScript(platformScript)
        contentController.addUserScript(
            WKUserScript(
                source: WebAuthBridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        config.userContentController = contentController

        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = false

        if #available(iOS 10.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        } else {
            config.requiresUserActionForMediaPlayback = false
        }

        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        self.webView = WKWebView(frame: .zero, configuration: config)

        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Force dark mode immediately to reduce flash
        if #available(iOS 13.0, *) {
            webView.overrideUserInterfaceStyle = .dark
        }

        let request = URLRequest(url: url)
        webView.load(request)
    }
}

// WebViewWrapper stays exactly the same as last version (pull-to-refresh fixed)
struct WebViewWrapper: UIViewRepresentable {

    @ObservedObject var store: WebViewStore

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = store.webView
        let contentController = webView.configuration.userContentController

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        contentController.removeScriptMessageHandler(forName: WebAuthBridgeScript.handlerName)
        contentController.add(context.coordinator.authStateHandler, name: WebAuthBridgeScript.handlerName)

        let refresh = UIRefreshControl()
        refresh.tintColor = .systemBlue
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.didPullToRefresh),
                          for: .valueChanged)

        webView.scrollView.refreshControl = refresh
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        private let parent: WebViewWrapper
        let authStateHandler = WebAuthScriptMessageHandler()
        private let allowedDomains: Set<String> = [
            "webefriends.com",
            "stripe.com",
            "stripe.network",
            "fairnewsfirst.com",
            "firebaseapp.com",
            "googleapis.com",
            "gstatic.com",
            "hosted.app"
        ]
        private let allowedEmbedHosts: Set<String> = [
            "youtube.com",
            "www.youtube.com",
            "youtube-nocookie.com",
            "www.youtube-nocookie.com",
            "youtu.be",
            "ytimg.com",
            "i.ytimg.com",
            "tiktok.com",
            "www.tiktok.com",
            "vm.tiktok.com",
            "vt.tiktok.com"
        ]

        init(_ parent: WebViewWrapper) {
            self.parent = parent
        }

        private func hostMatchesAllowedSet(_ host: String, allowedHosts: Set<String>) -> Bool {
            let normalizedHost = host.lowercased()
            return allowedHosts.contains { allowed in
                normalizedHost == allowed || normalizedHost.hasSuffix(".\(allowed)")
            }
        }

        private func hostIsAllowed(_ host: String) -> Bool {
            hostMatchesAllowedSet(host, allowedHosts: allowedDomains) ||
            hostMatchesAllowedSet(host, allowedHosts: allowedEmbedHosts)
        }

        @objc func didPullToRefresh() {
            parent.store.webView.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.parent.store.webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.path == "/native/external-checkout" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
                   let targetUrl = URL(string: target),
                   targetUrl.scheme == "https" {
                    UIApplication.shared.open(targetUrl)
                }
                decisionHandler(.cancel)
                return
            }

            if let host = url.host {
                if hostIsAllowed(host) {
                    decisionHandler(.allow)
                    return
                }
            }

            let isTopFrameNavigation = navigationAction.targetFrame?.isMainFrame ?? false
            let isExplicitUserTap = navigationAction.navigationType == .linkActivated

            if !isTopFrameNavigation {
                decisionHandler(.allow)
                return
            }

            if !isExplicitUserTap {
                decisionHandler(.allow)
                return
            }

            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {

            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url,
                   let host = url.host,
                   hostIsAllowed(host) {
                    webView.load(navigationAction.request)
                } else if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {

            let allowedHosts = [
                "webefriends.com",
                "studio--we-be-plus.us-central1.hosted.app",
                "fairnewsfirst.com",
                "stripe.com"
            ]

            let host = origin.host.lowercased()

            let isAllowed = allowedHosts.contains(where: { allowed in
                host == allowed || host.hasSuffix(".\(allowed)")
            })

            decisionHandler(isAllowed ? .grant : .deny)
        }
    }
}

struct ContentView: View {
    @StateObject private var network = NetworkMonitor()
    @StateObject private var store = WebViewStore(url: URL(string: "https://webefriends.com")!)
    @State private var isLoading = true

    var body: some View {
        ZStack {
            WebViewWrapper(store: store)
                .ignoresSafeArea()
                .opacity(isLoading ? 0 : 1)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {  // slightly faster fade
                        isLoading = false
                    }
                }

            if !network.isOnline {
                OfflineView {
                    store.webView.reload()
                }
                .transition(.opacity)
            }

            if isLoading {
                LoadingView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)   // Force dark mode at SwiftUI level
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("webeLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 220)

            ProgressView()
                .scaleEffect(1.2)

            Text("Loading We-Be…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)   // Solid black while loading
    }
}

struct OfflineView: View {
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))

            Text("No Internet Connection")
                .font(.title3)
                .bold()

            Text("Check your connection and try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Button("Retry") {
                retryAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.98))
    }
}
