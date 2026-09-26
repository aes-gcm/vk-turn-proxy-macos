import SwiftUI
import WebKit

/// Outcome of a VK login session.
enum VKAuthResult {
    /// Ready-to-send Cookie header ("remixsid=…; p=…") + the earlier expiry.
    case harvested(cookieHeader: String, expiry: Date)
    case cancelled
}

/// macOS port of the iOS VKAuthWebView. Embedded VK login for the captcha-free
/// "cookie" cred path (pkg/proxy/creds_vkcookie.go). The user signs into a
/// (burner) VK account manually — 2FA "just works" because it's a real browser
/// session. We watch the webview's own cookie store for the logged-in pair
/// `remixsid` (.vk.ru/.vk.com session) + `p` (.login.vk.* auth token); both are
/// HttpOnly, so they're only visible via WKHTTPCookieStore (not document.cookie).
struct VKLoginSheet: View {
    let onResult: (VKAuthResult) -> Void
    @State private var status = "Войдите в аккаунт VK (можно burner). 2FA поддерживается."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Вход в VK").font(.headline)
                Spacer()
                Button("Отмена") { onResult(.cancelled) }
            }
            .padding(12)

            VKAuthWebView(
                onHarvested: { header, expiry in onResult(.harvested(cookieHeader: header, expiry: expiry)) },
                onStatus: { status = $0 }
            )
            .frame(width: 560, height: 620)

            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
        }
        .frame(width: 560)
    }
}

/// NSViewRepresentable wrapping a WKWebView that loads VK login and polls its
/// cookie store for the remixsid + p pair.
struct VKAuthWebView: NSViewRepresentable {
    let onHarvested: (_ cookieHeader: String, _ expiry: Date) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHarvested: onHarvested, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent store → clean login each time (no stale account).
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = URL(string: "https://vk.ru/") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onHarvested: (_ cookieHeader: String, _ expiry: Date) -> Void
        let onStatus: (String) -> Void
        weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false

        init(onHarvested: @escaping (_ cookieHeader: String, _ expiry: Date) -> Void,
             onStatus: @escaping (String) -> Void) {
            self.onHarvested = onHarvested
            self.onStatus = onStatus
        }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.tryHarvest()
            }
        }

        func stopPolling() { timer?.invalidate(); timer = nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tryHarvest() }

        private func tryHarvest() {
            guard !done, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                var remixsid: HTTPCookie?
                var p: HTTPCookie?
                for c in cookies {
                    let domain = c.domain.hasPrefix(".") ? c.domain : "." + c.domain
                    if c.name == "remixsid", domain.hasSuffix(".vk.com") || domain.hasSuffix(".vk.ru") { remixsid = c }
                    if c.name == "p", domain.hasSuffix(".login.vk.com") || domain.hasSuffix(".login.vk.ru") { p = c }
                }
                guard let r = remixsid, let pp = p else {
                    self.onStatus("Ожидаю завершения входа…")
                    return
                }
                self.done = true
                self.stopPolling()
                let header = "remixsid=\(r.value); p=\(pp.value)"
                let fallback = Date().addingTimeInterval(30 * 24 * 3600)
                let expiry = min(r.expiresDate ?? fallback, pp.expiresDate ?? fallback)
                self.onStatus("Вход выполнен ✓")
                DispatchQueue.main.async { self.onHarvested(header, expiry) }
            }
        }
    }
}
