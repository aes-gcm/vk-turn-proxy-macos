import Foundation
import AppKit

/// Config handed to the root helper (JSON keys == Go fileConfig).
private struct HelperConfig: Codable {
    var vk_link: String
    var vk_cookie: String
    var peer: String
    var n: Int
    var mode: String
    var wg_private: String
    var wg_peer_pub: String
    var wg_psk: String
    var wg_address: String
    var wg_dns: String
    var allowed: String
    var keepalive: Int
    var mtu: Int
    var up: Bool
}

/// Runs the VK-TURN core as root. To avoid a password on EVERY connect, the
/// helper is installed once to a fixed path with a NOPASSWD sudoers rule (one
/// admin prompt, first connect only); afterwards connect/stop use `sudo -n`
/// with no prompt. (SMAppService needs a Developer ID we don't have, so a
/// sudoers rule is the no-account equivalent.)
@MainActor
final class Connection {
    /// Space-free path so the sudoers command spec parses cleanly.
    private let installedHelper = "/usr/local/bin/vkturn-helper"
    private let sudoersPath = "/etc/sudoers.d/vkturn"

    private var logTimer: Timer?
    private var logOffset: UInt64 = 0
    private var cancelled = false

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VKTurnProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var configURL: URL { supportDir.appendingPathComponent("config.json") }
    private var logURL: URL { supportDir.appendingPathComponent("core.log") }
    private var bundledHelper: URL? { Bundle.main.resourceURL?.appendingPathComponent("vkturn-macos") }

    // MARK: connect
    func connect(model: AppModel) {
        guard let bundled = bundledHelper, FileManager.default.fileExists(atPath: bundled.path) else {
            model.status = .error("движок не найден в бандле"); return
        }
        guard model.profile.isConfigured else {
            model.status = .error("заполните настройки сервера (вкладка «Сервер»)"); return
        }
        guard let cookie = model.vkCookie, model.isLoggedIn else {
            model.status = .error("сначала войдите в VK"); return
        }
        let link = model.vkLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { model.status = .error("нет ссылки на звонок"); return }

        let cfg = HelperConfig(
            vk_link: model.vkLink, vk_cookie: cookie,
            peer: model.profile.peerAddress, n: model.profile.numConnections,
            mode: model.profile.mode.cliMode,
            wg_private: model.profile.privateKey, wg_peer_pub: model.profile.peerPublicKey,
            wg_psk: model.profile.presharedKey, wg_address: model.profile.tunnelAddress,
            wg_dns: model.profile.dnsServers, allowed: "0.0.0.0/0",
            keepalive: 25, mtu: 1280, up: true
        )
        do {
            try JSONEncoder().encode(cfg).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            model.status = .error("не удалось записать конфиг: \(error.localizedDescription)"); return
        }
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        logOffset = 0
        cancelled = false
        model.status = .connecting
        model.log("[app] подключение…")

        let helper = installedHelper
        let cfgPath = configURL.path
        let logPath = logURL.path
        let bundledPath = bundled.path

        DispatchQueue.global().async {
            // 1) ensure the CURRENT helper is installed with a NOPASSWD rule
            //    (reinstall if the on-disk copy differs from the bundled one)
            let current = FileManager.default.contentsEqual(atPath: helper, andPath: bundledPath)
            if !current || !Self.probeInstalled(helper) {
                DispatchQueue.main.async { model.log("[app] первичная установка службы (нужен пароль один раз)…") }
                let ok = Self.install(bundled: bundledPath, dest: helper, sudoers: "/etc/sudoers.d/vkturn")
                if !ok {
                    DispatchQueue.main.async {
                        if !self.cancelled { model.status = .error("установка отменена/не удалась") }
                    }
                    return
                }
                DispatchQueue.main.async { model.log("[app] служба установлена ✓ (пароль больше не нужен)") }
            }
            if self.cancelled { return }
            // 2) launch as root without a prompt; helper writes its own pidfile
            let cmd = "sudo -n '\(helper)' -config '\(cfgPath)' > '\(logPath)' 2>&1 &"
            _ = Self.runSh(cmd)
            DispatchQueue.main.async {
                if !self.cancelled { self.startLogTail(model: model) }
            }
        }
    }

    // MARK: cancel / disconnect
    func cancel(model: AppModel) { teardown(model: model, note: "[app] отмена…") }
    func disconnect(model: AppModel) { teardown(model: model, note: "[app] отключение…") }

    private func teardown(model: AppModel, note: String) {
        cancelled = true
        logTimer?.invalidate(); logTimer = nil
        model.log(note)
        let helper = installedHelper
        DispatchQueue.global().async {
            _ = Self.runSh("sudo -n '\(helper)' -stop")
            DispatchQueue.main.async { model.status = .idle; model.log("[app] отключено") }
        }
    }

    // MARK: log tailing
    private func startLogTail(model: AppModel) {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.pumpLog(model: model)
        }
    }

    private func pumpLog(model: AppModel) {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: logOffset)
        let data = fh.readDataToEndOfFile()
        if data.isEmpty { return }
        logOffset += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            model.log(s)
            let low = s.lowercased()
            if s.contains("WireGuard device up") {
                model.status = .connected
            } else if s.contains("bootstrap READY") {
                model.log("[app] креды VK получены, поднимаю туннель…")
            } else if s.contains("another VPN is active") || s.contains("no physical gateway") {
                model.status = .error("другой VPN активен — выключите его и переподключитесь")
            } else if s.contains("bootstrap failed") || s.contains("CreateTUN")
                        || low.contains("fatal") || s.contains("IpcSet")
                        || s.contains("device.Up") || low.contains("panic") {
                model.status = .error(shortError(s))
            }
        }
    }

    private func shortError(_ s: String) -> String {
        let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count == 3, parts[0].contains("/"), parts[1].contains(":") {
            return String(String(parts[2]).prefix(90))
        }
        return String(s.prefix(90))
    }

    // MARK: helpers (nonisolated: run on background threads)
    nonisolated private static func probeInstalled(_ helper: String) -> Bool {
        guard FileManager.default.fileExists(atPath: helper) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helper, "-check"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// One-time privileged install: copy the helper to a fixed path and add a
    /// NOPASSWD sudoers rule for the current user. Returns false if cancelled.
    nonisolated private static func install(bundled: String, dest: String, sudoers: String) -> Bool {
        let user = NSUserName()
        let script = [
            "mkdir -p /usr/local/bin",
            "cp '\(bundled)' '\(dest)'",
            "chown root:wheel '\(dest)'",
            "chmod 755 '\(dest)'",
            "printf '%s\\n' '\(user) ALL=(root) NOPASSWD: \(dest)' > '\(sudoers)'",
            "chown root:wheel '\(sudoers)'",
            "chmod 440 '\(sudoers)'",
        ].joined(separator: "; ")
        let apple = "do shell script \"\(script)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @discardableResult
    nonisolated private static func runSh(_ cmd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
