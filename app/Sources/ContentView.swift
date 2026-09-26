import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLogin = false
    @State private var showOAuth = false
    @State private var showImport = false
    @State private var importText = ""
    @State private var creatingLink = false
    @State private var banner: String?
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            connectionTab
                .tabItem { Label("Подключение", systemImage: "bolt.horizontal.circle") }.tag(0)
            serverTab
                .tabItem { Label("Сервер", systemImage: "server.rack") }.tag(1)
            logTab
                .tabItem { Label("Журнал", systemImage: "text.alignleft") }.tag(2)
        }
        .frame(width: 460, height: 600)
        .sheet(isPresented: $showLogin) { loginSheet }
        .sheet(isPresented: $showOAuth) { oauthSheet }
        .sheet(isPresented: $showImport) { importSheet }
    }

    // MARK: — Connection tab
    private var connectionTab: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // hero
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(model.status.tint.opacity(0.15)).frame(width: 104, height: 104)
                    if model.status.isBusy {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: model.status.symbolName)
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(model.status.tint)
                    }
                }
                Text(model.status.label)
                    .font(.title2.weight(.semibold))
                if case .connected = model.status {
                    Text("через \(model.profile.peerAddress) · \(model.profile.mode.label)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)

            // primary action
            primaryButton.padding(.horizontal, 28)

            if let hint = readinessHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 8).multilineTextAlignment(.center)
            }

            Spacer(minLength: 24)
            Divider().padding(.horizontal, 20)

            // compact status rows
            VStack(spacing: 10) {
                infoRow(icon: "person.crop.circle.fill",
                        title: "Аккаунт VK",
                        detail: model.loginValidText,
                        ok: model.isLoggedIn) {
                    if model.isLoggedIn {
                        Button("Выйти") { model.logout() }.controlSize(.small)
                    } else {
                        Button("Войти") { showLogin = true }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                    }
                }
                infoRow(icon: "phone.arrow.up.right.fill",
                        title: "Ссылка на звонок",
                        detail: model.vkLink.isEmpty ? "не создана" : model.vkLink,
                        ok: !model.vkLink.isEmpty) {
                    if creatingLink {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Создать") { createLink() }
                            .controlSize(.small).disabled(!model.isLoggedIn)
                    }
                }
            }
            .padding(16)

            if let b = banner {
                Text(b).font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.status {
        case .connected:
            Button(role: .destructive) { model.connection.disconnect(model: model) } label: {
                Text("Отключить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        case .connecting, .loggingIn:
            Button(role: .cancel) { model.connection.cancel(model: model) } label: {
                Text("Отменить подключение").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        default:
            Button { banner = nil; model.connection.connect(model: model) } label: {
                Text("Подключить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!isReady)
        }
    }

    private var isReady: Bool {
        model.isLoggedIn && model.profile.isConfigured && !model.vkLink.isEmpty
    }

    private var readinessHint: String? {
        if model.status == .connected || model.status.isBusy { return nil }
        if !model.isLoggedIn { return "Войдите в аккаунт VK" }
        if model.vkLink.isEmpty { return "Создайте ссылку на звонок" }
        if !model.profile.isConfigured { return "Заполните сервер во вкладке «Сервер»" }
        return nil
    }

    private func infoRow<Trailing: View>(icon: String, title: String, detail: String,
                                         ok: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18))
                .foregroundStyle(ok ? Color.green : Color.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: — Server tab
    private var serverTab: some View {
        Form {
            Section {
                TextField("Название", text: $model.profile.serverName)
                Button {
                    showImport = true
                } label: {
                    Label("Импорт по ссылке…", systemImage: "square.and.arrow.down")
                }
            }
            Section("Сервер") {
                TextField("Адрес (host:port)", text: $model.profile.peerAddress,
                          prompt: Text("185.247.224.46:56000"))
                Picker("Режим", selection: $model.profile.mode) {
                    ForEach(TransportMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("WireGuard") {
                SecureField("Private Key", text: $model.profile.privateKey, prompt: Text("base64"))
                SecureField("Peer Public Key", text: $model.profile.peerPublicKey, prompt: Text("base64"))
                SecureField("Preshared Key", text: $model.profile.presharedKey, prompt: Text("base64 · опционально"))
                TextField("Tunnel Address", text: $model.profile.tunnelAddress, prompt: Text("10.66.66.5/24"))
                TextField("DNS", text: $model.profile.dnsServers, prompt: Text("1.1.1.1"))
                Stepper("Соединений: \(model.profile.numConnections)",
                        value: $model.profile.numConnections, in: 1...50)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.profile) { _ in model.save() }
        .onChange(of: model.vkLink) { _ in model.save() }
    }

    // MARK: — Log tab
    private var logTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logLines.isEmpty ? "Журнал пуст." : model.logLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("logEnd")
                }
                .onChange(of: model.logLines.count) { _ in
                    withAnimation { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Button { NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
                } label: { Label("Копировать", systemImage: "doc.on.doc") }
                Spacer()
                Button("Очистить") { model.clearLog() }
            }
            .padding(8)
        }
    }

    // MARK: — Sheets
    private var loginSheet: some View {
        VKLoginSheet { result in
            showLogin = false
            if case let .harvested(header, expiry) = result {
                model.setCookie(header, expiry: expiry)
                banner = "Вход выполнен ✓"
            }
        }
    }

    private var oauthSheet: some View {
        Group {
            if let cookie = model.vkCookie, let expiry = model.vkCookieExpiry {
                VKOAuthSheet(cookieHeader: cookie, cookieExpiry: expiry) { result in
                    showOAuth = false
                    handleOAuth(result)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Сначала войдите в VK").font(.headline)
                    Button("Закрыть") { showOAuth = false }
                }.padding(30)
            }
        }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Импорт по ссылке").font(.headline)
            Text("Вставь vkturnproxy://… или base64 (совместимо с iOS / quick_link.py).")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $importText).frame(width: 440, height: 110)
                .font(.system(size: 11, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
            HStack {
                Button("Вставить из буфера") {
                    importText = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                Button("Отмена") { showImport = false }
                Button("Импортировать") { doImport() }
                    .buttonStyle(.borderedProminent).disabled(importText.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }

    // MARK: — Actions
    private func createLink() {
        guard model.isLoggedIn else { banner = "Сначала войдите в VK"; return }
        showOAuth = true
    }

    private func handleOAuth(_ result: VKOAuthResult) {
        switch result {
        case let .token(token):
            creatingLink = true
            banner = "Создаём звонок…"
            Task {
                let r = await VKCallsAPI.startCall(accessToken: token)
                await MainActor.run {
                    creatingLink = false
                    switch r {
                    case let .success(c):
                        model.vkLink = c.joinLink; model.save()
                        banner = "Ссылка создана ✓"
                        model.log("[vk] звонок создан: \(c.joinLink)")
                    case let .failure(e):
                        banner = "Не удалось: \(e.userMessage)"
                        model.log("[vk] calls.start: \(e.userMessage)")
                    }
                }
            }
        case .needsLogin: banner = "Нужен повторный вход в VK"
        case let .failed(m): banner = "OAuth: \(m)"
        case .cancelled: break
        }
    }

    private func doImport() {
        guard let s = ConnectionLink.parse(importText) else { banner = "Не распознал ссылку"; return }
        ConnectionLink.apply(s, to: model)
        showImport = false
        importText = ""
        banner = "Импортировано ✓"
        tab = 1
    }
}
