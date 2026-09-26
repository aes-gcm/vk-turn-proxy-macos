import SwiftUI

/// VK Turn Proxy — native macOS menu-bar client.
///
/// Architecture: this app is a pure Swift front-end. It performs the VK
/// WebView login (captcha-free cred cookie) and the OAuth + calls.start
/// auto-link, assembles a connection config, and hands it to the privileged
/// `vkturn-macos` helper (the Go core + real utun, run as root). The core is
/// never linked into this process.
@main
struct VKTurnProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Menu-bar presence (LSUIElement = true → no Dock icon).
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.status.symbolName)
        }
        .menuBarExtraStyle(.window)

        // Main window (login / server profile / logs), opened from the menu.
        Window("VK Turn Proxy", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 460, height: 600)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app: closing the window must not quit.
        false
    }
}
