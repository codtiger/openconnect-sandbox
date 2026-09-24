import AppKit
import OpenConnectSandboxCore
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                Text("No VPN profiles")
            } else {
                ForEach(model.profiles) { profile in
                    ProfileMenuItem(profile: profile)
                        .environmentObject(model)
                }
            }

            Divider()
            Button("Copy Environment Reset") { model.copyEnvironmentReset() }
            Button("Connections…") {
                activateApplication()
                openWindow(id: "connections")
                DispatchQueue.main.async { bringConnectionsWindowForward() }
            }
            .keyboardShortcut(",", modifiers: [.command])

            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit OpenConnect Sandbox") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { activateApplication() }
    }

    private func activateApplication() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func bringConnectionsWindowForward() {
        NSApp.windows.first(where: { $0.title == "OpenConnect Sandbox" })?.makeKeyAndOrderFront(nil)
    }
}

private struct ProfileMenuItem: View {
    @EnvironmentObject private var model: AppModel
    let profile: VPNProfile

    var body: some View {
        if let session = model.session(for: profile.id) {
            RunningProfileMenuItem(profile: profile, session: session)
                .environmentObject(model)
        } else {
            Button {
                model.connect(profile.id)
            } label: {
                Label("\(profile.name) — Connect", systemImage: "circle")
            }
        }
    }
}

private struct RunningProfileMenuItem: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: SupervisorClient
    let profile: VPNProfile

    init(profile: VPNProfile, session: SupervisorClient) {
        self.profile = profile
        self.session = session
    }

    var body: some View {
        Menu {
            Button("Disconnect") { model.disconnect(profile.id) }
                .disabled(session.phase == .stopping)
            Button("Copy Proxy Environment") { model.copyEnvironment(for: profile) }
                .disabled(session.phase != .connected)
            Button("Copy Environment Reset") { model.copyEnvironmentReset() }
            Button("Open Shell") { model.openShell(for: profile) }
                .disabled(session.phase != .connected)
        } label: {
            Label("\(profile.name) — \(session.phase.rawValue.capitalized)", systemImage: icon)
        }
    }

    private var icon: String {
        switch session.phase {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopping, .connecting, .authenticating, .reconnecting: return "arrow.triangle.2.circlepath"
        case .stopped: return "circle"
        }
    }
}
