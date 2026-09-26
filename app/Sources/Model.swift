import SwiftUI
import WebKit

enum ConnectionStatus: Equatable {
    case idle
    case loggingIn
    case connecting
    case connected
    case error(String)

    var symbolName: String {
        switch self {
        case .idle:       return "globe"
        case .loggingIn:  return "person.crop.circle.badge.clock"
        case .connecting: return "globe.badge.chevron.backward"
        case .connected:  return "globe.americas.fill"
        case .error:      return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .idle:       return "Отключено"
        case .loggingIn:  return "Вход в VK…"
        case .connecting: return "Подключение…"
        case .connected:  return "Подключено"
        case .error(let m): return "Ошибка: \(m)"
        }
    }

    var isBusy: Bool { self == .loggingIn || self == .connecting }

    var tint: Color {
        switch self {
        case .idle:       return .secondary
        case .loggingIn, .connecting: return .orange
        case .connected:  return .green
        case .error:      return .red
        }
    }
}

/// Transport mode — mirrors ServerProfile booleans in the iOS core.
enum TransportMode: String, CaseIterable, Identifiable, Codable {
    case srtp   // DTLS+SRTP (recommended; bypasses VK shaping)
    case dtls   // legacy DTLS+WG over TCP
    case udp    // legacy DTLS+WG over UDP-to-TURN
    var id: String { rawValue }
    var label: String {
        switch self {
        case .srtp: return "SRTP (рекоменд.)"
        case .dtls: return "Legacy DTLS+WG (TCP)"
        case .udp:  return "Legacy DTLS+WG (UDP)"
        }
    }
    /// Value for the CLI -mode flag / config.
    var cliMode: String { rawValue }
}

/// A named server profile — the WG identity + transport for one deployment.
/// Field names mirror iOS ServerProfile so imported connection links map 1:1.
struct ServerProfile: Codable, Equatable {
    var serverName: String = "Server1"
    var privateKey: String = ""       // WG client private (base64)
    var peerPublicKey: String = ""    // WG server public (base64)
    var presharedKey: String = ""     // optional (base64)
    var tunnelAddress: String = "10.66.66.5/24"
    var peerAddress: String = ""      // vk-turn-proxy server host:port
    var dnsServers: String = "1.1.1.1"
    var numConnections: Int = 30
    var mode: TransportMode = .srtp
    var turnServerOverride: String = ""

    var isConfigured: Bool {
        !peerAddress.isEmpty && !privateKey.isEmpty && !peerPublicKey.isEmpty
    }
}

/// What we persist between launches (UserDefaults, JSON).
private struct Persisted: Codable {
    var vkCookie: String?
    var vkCookieExpiry: Date?
    var vkLink: String
    var profile: ServerProfile
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status: ConnectionStatus = .idle
    @Published var vkCookie: String? = nil
    @Published var vkCookieExpiry: Date? = nil
    @Published var vkLink: String = ""              // VK call link (global)
    @Published var profile = ServerProfile()
    @Published var logLines: [String] = []

    let connection = Connection()
    private let defaultsKey = "vkturn.state.v1"

    init() { load() }

    var isLoggedIn: Bool {
        guard let exp = vkCookieExpiry else { return vkCookie != nil }
        return vkCookie != nil && exp > Date()
    }

    /// "Вход действителен до 5 сент. 2027, 14:30" — like iOS shows.
    var loginValidText: String {
        guard vkCookie != nil else { return "Вход не выполнен" }
        guard let exp = vkCookieExpiry else { return "Вход выполнен" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateStyle = .medium
        df.timeStyle = .short
        if exp <= Date() { return "Сессия истекла — войдите заново" }
        return "Вход действителен до \(df.string(from: exp))"
    }

    func setCookie(_ header: String, expiry: Date) {
        vkCookie = header
        vkCookieExpiry = expiry
        log("[vk] cookie получены, действ. до \(expiry)")
        save()
    }

    func logout() {
        vkCookie = nil
        vkCookieExpiry = nil
        // wipe any WKWebView data so the next login is a clean session
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types,
                                                modifiedSince: .distantPast) { }
        log("[vk] выход выполнен")
        save()
    }

    func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 4000 { logLines.removeFirst(logLines.count - 4000) }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: persistence
    func save() {
        let p = Persisted(vkCookie: vkCookie, vkCookieExpiry: vkCookieExpiry,
                          vkLink: vkLink, profile: profile)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        vkCookie = p.vkCookie
        vkCookieExpiry = p.vkCookieExpiry
        vkLink = p.vkLink
        profile = p.profile
    }
}
