import SwiftUI
import WebKit

enum VKOAuthResult {
    case token(String)     // user access token, scope=calls (used once, never stored)
    case needsLogin        // injected cookies didn't authenticate → log in first
    case failed(String)
    case cancelled
}

enum VKOAuth {
    static let clientID = "6287487"          // VK's own web app id → scope=calls
    static let redirectHost = "oauth.vk.ru"
    static let redirectPath = "/blank.html"

    static var authorizeURL: URL? {
        URL(string: "https://oauth.vk.ru/authorize?client_id=\(clientID)&scope=calls&response_type=token")
    }

    /// Which domain each stored cookie must be planted on so the OAuth identity
    /// gate sees it. remixsid on .vk.ru, p on .login.vk.ru (measured on iOS).
    static func domain(forCookie name: String) -> String? {
        switch name {
        case "remixsid": return ".vk.ru"
        case "p":        return ".login.vk.ru"
        default:         return nil
        }
    }

    static func cookies(fromHeader header: String, expiry: Date) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            let name = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, let domain = domain(forCookie: name) else { return nil }
            return HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain,
                .path: "/", .secure: "TRUE", .expires: expiry,
            ])
        }
    }

    static func token(fromRedirect url: URL) -> String? {
        guard url.host == redirectHost, url.path == redirectPath,
              let fragment = url.fragment else { return nil }
        for part in fragment.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "access_token", !kv[1].isEmpty {
                return String(kv[1])
            }
        }
        return nil
    }
}

/// Sheet that runs the OAuth implicit flow. Plants the stored login cookies so
/// the user only taps "Продолжить как …" — which is also the one place they see
/// WHOSE account will own the call.
struct VKOAuthSheet: View {
    let cookieHeader: String
    let cookieExpiry: Date
    let onResult: (VKOAuthResult) -> Void
    @State private var status = "Открываем VK ID…"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Создание звонка VK").font(.headline)
                Spacer()
                Button("Отмена") { onResult(.cancelled) }
            }
            .padding(12)

            VKOAuthWebView(
                cookieHeader: cookieHeader, cookieExpiry: cookieExpiry,
                onToken: { onResult(.token($0)) },
                onNeedsLogin: { onResult(.needsLogin) },
                onStatus: { status = $0 }
            )
            .frame(width: 560, height: 600)

            Text(status).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(8)
        }
        .frame(width: 560)
    }
}

struct VKOAuthWebView: NSViewRepresentable {
    let cookieHeader: String
    let cookieExpiry: Date
    let onToken: (String) -> Void
    let onNeedsLogin: () -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onNeedsLogin: onNeedsLogin, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let store = config.websiteDataStore.httpCookieStore
        let cookies = VKOAuth.cookies(fromHeader: cookieHeader, expiry: cookieExpiry)
        let group = DispatchGroup()
        for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
        group.notify(queue: .main) {
            if let url = VKOAuth.authorizeURL { webView.load(URLRequest(url: url)) }
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        let onNeedsLogin: () -> Void
        let onStatus: (String) -> Void
        private var done = false

        init(onToken: @escaping (String) -> Void, onNeedsLogin: @escaping () -> Void,
             onStatus: @escaping (String) -> Void) {
            self.onToken = onToken; self.onNeedsLogin = onNeedsLogin; self.onStatus = onStatus
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !done, let url = navigationAction.request.url,
               let token = VKOAuth.token(fromRedirect: url) {
                done = true
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onToken(token) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, let url = webView.url else { return }
            // If VK bounces to the sign-in form, our cookies didn't authenticate.
            if url.absoluteString.contains("/auth") || url.host?.contains("id.vk") == true {
                onStatus("Подтвердите аккаунт в открывшемся окне…")
            }
        }
    }
}
