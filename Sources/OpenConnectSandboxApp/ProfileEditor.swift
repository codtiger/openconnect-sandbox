import OpenConnectSandboxCore
import SwiftUI

struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var profile: VPNProfile
    @State private var showingLogs = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 640

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if compact {
                        VStack(alignment: .leading, spacing: 10) {
                            connectionSummary
                            HStack {
                                Spacer()
                                connectionButton
                            }
                        }
                    } else {
                    HStack {
                        connectionSummary
                        Spacer(minLength: 16)
                        connectionButton
                    }
                    }

                    GroupBox("Connection") {
                        VStack(spacing: 12) {
                            EditorField("Authentication", compact: compact) {
                                Picker("Authentication", selection: $profile.authenticationMode) {
                                    ForEach(AuthenticationMode.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                            EditorField("Server", compact: compact) {
                                TextField("Server", text: $profile.server, prompt: Text("https://vpn.example.com/group"))
                            }
                            EditorField("Protocol", compact: compact) {
                                Picker("Protocol", selection: $profile.vpnProtocol) {
                                    ForEach(VPNProtocol.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                            }
                            if profile.authenticationMode == .openConnect {
                                EditorField("Username", compact: compact) {
                                    TextField("Username", text: $profile.username)
                                }
                            }
                            EditorField("Authentication group", compact: compact) {
                                TextField("Authentication group", text: $profile.authGroup)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isActive)

                    if profile.authenticationMode == .openConnect {
                        GroupBox("Credentials") {
                            VStack(spacing: 12) {
                                EditorField("Password", compact: compact) {
                                    SecureField(model.hasSavedPassword(profile.id) ? "Saved in Keychain (leave blank to use)" : "Password (optional)", text: passwordBinding)
                                }
                                EditorField("One-time code", compact: compact) {
                                    SecureField("Never saved", text: codeBinding)
                                }
                                if compact {
                                    VStack(alignment: .leading, spacing: 8) {
                                        directCredentialButtons
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                HStack {
                                    directCredentialButtons
                                }
                            }
                        }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isActive)
                    } else {
                        GroupBox("Browser SSO") {
                            VStack(alignment: .leading, spacing: 12) {
                            Toggle("Remember SSO browser session", isOn: $profile.rememberSSOSession)
                            Text("Keeps only this profile's Qt browser cookies and site data. All SSO, Qt, OpenConnect, and supervisor processes still terminate on disconnect or app quit.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Clear Remembered SSO Session", role: .destructive) {
                                model.clearRememberedSSOSession(for: profile.id)
                            }
                            .disabled(isActive || !model.hasRememberedSSOSession(profile.id))

                            Divider()
                            Toggle("Autofill username and password from Keychain", isOn: $profile.rememberSSOCredentials)
                            if profile.rememberSSOCredentials {
                                EditorField("SSO username", compact: compact) {
                                    TextField("SSO username", text: ssoUsernameBinding)
                                }
                                EditorField("SSO password", compact: compact) {
                                    SecureField(
                                        model.hasSavedSSOCredentials(profile.id) ? "Saved in Keychain (leave blank to use)" : "SSO password",
                                        text: passwordBinding
                                    )
                                }
                                if compact {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ssoCredentialButtons
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    HStack {
                                        ssoCredentialButtons
                                    }
                                }
                            }
                            Text("No TOTP seed is requested or stored. Duo Push remains controlled by your identity provider's policy.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isActive)
                    }

                    GroupBox("Local proxy") {
                        VStack(spacing: 12) {
                            EditorField("SOCKS port", compact: compact) {
                                TextField("SOCKS port", value: $profile.socksPort, format: .number)
                            }
                            EditorField("Address", compact: compact) {
                                Text("socks5h://127.0.0.1:\(profile.socksPort)")
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        Text("The proxy is loopback-only. System routes and DNS are never changed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isActive)

                    GroupBox("Port forwards") {
                        VStack(spacing: 8) {
                            ForEach(profile.localForwards.indices, id: \.self) { index in
                                PortForwardEditorRow(forward: $profile.localForwards[index], compact: compact) {
                                    profile.localForwards.remove(at: index)
                                }
                            }
                            Button("Add Port Forward") { profile.localForwards.append(LocalForward()) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isActive)

                    GroupBox("Behavior and advanced options") {
                        VStack(alignment: .leading, spacing: 12) {
                        Toggle("Reconnect after an unexpected failure", isOn: $profile.autoReconnect)
                        Toggle("Connect when the application launches", isOn: $profile.connectOnLaunch)
                            EditorField("Additional arguments", compact: compact) {
                                TextField("One OpenConnect argument per line", text: additionalArgumentsBinding, axis: .vertical)
                                    .lineLimit(2...6)
                            }
                        Text("Arguments capable of changing scripts, interfaces, credentials, or background behavior are rejected.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isActive)

                    if compact {
                        VStack(alignment: .leading, spacing: 8) {
                            actionButtons
                            logsButton
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                        actionButtons
                        Spacer()
                        logsButton
                    }
                    }

                    if showingLogs {
                        LogView(session: model.session(for: profile.id))
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(model.session(for: profile.id)?.phase == .stopping)
    }

    private var session: SupervisorClient? { model.session(for: profile.id) }
    private var isActive: Bool { session.map { $0.phase != .stopped && $0.phase != .failed } ?? false }
    private var isConnected: Bool { session?.phase == .connected }
    private var statusText: String { session?.phase.rawValue.capitalized ?? "Stopped" }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Connection name", text: $profile.name)
                .font(.title2.bold()).textFieldStyle(.plain)
                .disabled(isActive)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionButton: some View {
        Button(isActive ? "Disconnect" : "Connect") { model.toggle(profile.id) }
            .buttonStyle(.borderedProminent)
            .tint(isActive ? .red : .accentColor)
    }

    @ViewBuilder
    private var directCredentialButtons: some View {
        Button("Save Password in Keychain") { model.savePassword(for: profile.id) }
        if model.hasSavedPassword(profile.id) {
            Button("Forget Saved Password", role: .destructive) { model.forgetPassword(for: profile.id) }
        }
    }

    @ViewBuilder
    private var ssoCredentialButtons: some View {
        Button("Save SSO Credentials in Keychain") {
            model.saveSSOCredentials(for: profile.id)
        }
        if model.hasSavedSSOCredentials(profile.id) {
            Button("Forget SSO Credentials", role: .destructive) {
                model.forgetSSOCredentials(for: profile.id)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Copy Proxy Environment") { model.copyEnvironment(for: profile) }
        Button("Copy Environment Reset") { model.copyEnvironmentReset() }
        Button("Open Shell") { model.openShell(for: profile) }.disabled(!isConnected)
        Button("Duplicate") { model.duplicateProfile(profile.id) }
    }

    private var logsButton: some View {
        Button(showingLogs ? "Hide Logs" : "Show Logs") { showingLogs.toggle() }
    }

    private var passwordBinding: Binding<String> {
        Binding(get: { model.transientPasswords[profile.id] ?? "" }, set: { model.transientPasswords[profile.id] = $0 })
    }
    private var codeBinding: Binding<String> {
        Binding(get: { model.transientCodes[profile.id] ?? "" }, set: { model.transientCodes[profile.id] = $0 })
    }
    private var ssoUsernameBinding: Binding<String> {
        Binding(
            get: { model.transientSSOUsernames[profile.id] ?? "" },
            set: { model.transientSSOUsernames[profile.id] = $0 }
        )
    }
    private var additionalArgumentsBinding: Binding<String> {
        Binding(
            get: { profile.additionalArguments.joined(separator: "\n") },
            set: { profile.additionalArguments = $0.split(whereSeparator: \.isNewline).map(String.init) }
        )
    }
}

private struct EditorField<Content: View>: View {
    let title: String
    let compact: Bool
    @ViewBuilder let content: Content

    init(_ title: String, compact: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .frame(width: 165, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PortForwardEditorRow: View {
    @Binding var forward: LocalForward
    let compact: Bool
    let remove: () -> Void

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Local port")
                TextField("Local port", value: $forward.localPort, format: .number)
                fieldLabel("Remote host")
                TextField("Remote host", text: $forward.remoteHost)
                fieldLabel("Remote port")
                TextField("Remote port", value: $forward.remotePort, format: .number)
                Button("Remove Port Forward", role: .destructive, action: remove)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                TextField("Local", value: $forward.localPort, format: .number)
                    .frame(width: 80)
                Image(systemName: "arrow.right")
                TextField("Remote host", text: $forward.remoteHost)
                    .frame(minWidth: 170)
                TextField("Port", value: $forward.remotePort, format: .number)
                    .frame(width: 80)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
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
