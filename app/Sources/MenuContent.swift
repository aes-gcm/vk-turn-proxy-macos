import SwiftUI

/// The dropdown shown from the menu-bar icon.
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.status.symbolName)
                Text(model.status.label).font(.headline)
            }

            Divider()

            if model.isLoggedIn {
                Label("VK: вход выполнен", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("VK: не выполнен вход", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Открыть окно…", systemImage: "macwindow")
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Выход", systemImage: "power")
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
