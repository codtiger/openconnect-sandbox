import OpenConnectSandboxCore
import SwiftUI

struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var profile: VPNProfile
    @State private var showingLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Connection name", text: $profile.name)
                            .font(.title2.bold()).textFieldStyle(.plain)
                            .disabled(isActive)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isActive ? "Disconnect" : "Connect") { model.toggle(profile.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(isActive ? .red : .accentColor)
                }

                GroupBox("Connection") {
                    Form {
                        Picker("Authentication", selection: $profile.authenticationMode) {
                            ForEach(AuthenticationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        TextField("Server", text: $profile.server, prompt: Text("https://vpn.example.com/group"))
                        Picker("Protocol", selection: $profile.vpnProtocol) {
                            ForEach(VPNProtocol.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if profile.authenticationMode == .openConnect {
                            TextField("Username", text: $profile.username)
                        }
                        TextField("Authentication group", text: $profile.authGroup)
                    }
                    .padding(8)
                }
                .disabled(isActive)

                if profile.authenticationMode == .openConnect {
                    GroupBox("Credentials") {
                        Form {
                            SecureField(model.hasSavedPassword(profile.id) ? "Saved in Keychain (leave blank to use)" : "Password (optional)", text: passwordBinding)
                            SecureField("One-time code (never saved)", text: codeBinding)
                            HStack {
                                Button("Save Password in Keychain") { model.savePassword(for: profile.id) }
                                if model.hasSavedPassword(profile.id) {
                                    Button("Forget Saved Password", role: .destructive) { model.forgetPassword(for: profile.id) }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .disabled(isActive)
                } else {
                    GroupBox("Browser SSO") {
                        Text("Authentication is completed in openconnect-sso's temporary browser session. The app does not inject or save SSO credentials or TOTP secrets.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }

                GroupBox("Local proxy") {
                    Form {
                        TextField("SOCKS port", value: $profile.socksPort, format: .number)
                        LabeledContent("Address", value: "socks5h://127.0.0.1:\(profile.socksPort)")
                        Text("The proxy is loopback-only. System routes and DNS are never changed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                .disabled(isActive)

                GroupBox("Port forwards") {
                    VStack(spacing: 8) {
                        ForEach(profile.localForwards.indices, id: \.self) { index in
                            HStack {
                                TextField("Local", value: $profile.localForwards[index].localPort, format: .number).frame(width: 80)
                                Image(systemName: "arrow.right")
                                TextField("Remote host", text: $profile.localForwards[index].remoteHost)
                                TextField("Port", value: $profile.localForwards[index].remotePort, format: .number).frame(width: 80)
                                Button(role: .destructive) { profile.localForwards.remove(at: index) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain)
                            }
                        }
                        Button("Add Port Forward") { profile.localForwards.append(LocalForward()) }
                    }
                    .padding(8)
                }
                .disabled(isActive)

                GroupBox("Behavior and advanced options") {
                    Form {
                        Toggle("Reconnect after an unexpected failure", isOn: $profile.autoReconnect)
                        Toggle("Connect when the application launches", isOn: $profile.connectOnLaunch)
                        TextField("Additional OpenConnect arguments (one per line)", text: additionalArgumentsBinding, axis: .vertical)
                            .lineLimit(2...6)
                        Text("Arguments capable of changing scripts, interfaces, credentials, or background behavior are rejected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                .disabled(isActive)

                HStack {
                    Button("Copy Proxy Environment") { model.copyEnvironment(for: profile) }
                    Button("Open Shell") { model.openShell(for: profile) }.disabled(!isConnected)
                    Button("Duplicate") { model.duplicateProfile(profile.id) }
                    Spacer()
                    Button(showingLogs ? "Hide Logs" : "Show Logs") { showingLogs.toggle() }
                }

                if showingLogs {
                    LogView(session: model.session(for: profile.id))
                }
            }
            .padding(22)
        }
        .disabled(model.session(for: profile.id)?.phase == .stopping)
    }

    private var session: SupervisorClient? { model.session(for: profile.id) }
    private var isActive: Bool { session.map { $0.phase != .stopped && $0.phase != .failed } ?? false }
    private var isConnected: Bool { session?.phase == .connected }
    private var statusText: String { session?.phase.rawValue.capitalized ?? "Stopped" }
    private var passwordBinding: Binding<String> {
        Binding(get: { model.transientPasswords[profile.id] ?? "" }, set: { model.transientPasswords[profile.id] = $0 })
    }
    private var codeBinding: Binding<String> {
        Binding(get: { model.transientCodes[profile.id] ?? "" }, set: { model.transientCodes[profile.id] = $0 })
    }
    private var additionalArgumentsBinding: Binding<String> {
        Binding(
            get: { profile.additionalArguments.joined(separator: "\n") },
            set: { profile.additionalArguments = $0.split(whereSeparator: \.isNewline).map(String.init) }
        )
    }
}

private struct LogView: View {
    @ObservedObject var session: SupervisorClient

    init(session: SupervisorClient?) {
        self.session = session ?? SupervisorClient(profileID: UUID(), socksPort: 0)
    }

    var body: some View {
        ScrollView {
            Text(session.logs.isEmpty ? "No logs for this session." : session.logs.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 130, maxHeight: 260)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
