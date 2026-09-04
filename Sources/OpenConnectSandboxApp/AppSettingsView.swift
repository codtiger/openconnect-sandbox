import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("disconnectOnSleep") private var disconnectOnSleep = true

    var body: some View {
        Form {
            Section("Executables") {
                ExecutablePathRow(label: "OpenConnect", path: $model.toolPaths.openConnect)
                ExecutablePathRow(label: "ocproxy", path: $model.toolPaths.ocproxy)
                ExecutablePathRow(label: "OpenConnect SSO", path: $model.toolPaths.openConnectSSO)
                Button("Detect Installed Tools") { model.redetectTools() }
            }
            Section("Lifecycle") {
                Toggle("Launch application at login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Disconnect all connections when this Mac sleeps", isOn: $disconnectOnSleep)
                Text("No daemon or privileged helper is installed. Quitting the application closes every managed process.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onDisappear { model.persist() }
    }
}

private struct ExecutablePathRow: View {
    let label: String
    @Binding var path: String

    var body: some View {
        HStack {
            TextField(label, text: $path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
        }
    }
}
