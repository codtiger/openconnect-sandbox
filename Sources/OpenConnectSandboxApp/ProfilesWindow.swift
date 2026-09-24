import OpenConnectSandboxCore
import SwiftUI

struct ProfilesWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedProfileID) {
                    ForEach(model.profiles) { profile in
                        ProfileSidebarRow(profile: profile)
                            .environmentObject(model)
                            .tag(profile.id)
                    }
                }
                Divider()
                HStack {
                    Button { model.addProfile() } label: { Image(systemName: "plus") }
                    Button {
                        if let id = model.selectedProfileID { model.deleteProfile(id) }
                    } label: { Image(systemName: "minus") }
                    .disabled(model.selectedProfileID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationTitle("Connections")
            .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            Group {
                if let id = model.selectedProfileID, model.profile(id: id) != nil {
                    ProfileDetail(profileID: id)
                        .environmentObject(model)
                } else {
                    ContentUnavailableView("No Connection Selected", systemImage: "lock.shield", description: Text("Add or select a VPN connection."))
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 680)
        }
        .alert("OpenConnect Sandbox", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ProfileSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: VPNProfile

    var body: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(profile.name)
                Text("127.0.0.1:\(profile.socksPort)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        guard let phase = model.session(for: profile.id)?.phase else { return .secondary }
        switch phase {
        case .connected: return .green
        case .failed: return .red
        case .stopped: return .secondary
        default: return .orange
        }
    }
}

private struct ProfileDetail: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID

    var body: some View {
        if let index = model.profiles.firstIndex(where: { $0.id == profileID }) {
            ProfileEditor(profile: Binding(
                get: { model.profiles[index] },
                set: { model.updateProfile($0) }
            ))
            .environmentObject(model)
        }
    }
}
