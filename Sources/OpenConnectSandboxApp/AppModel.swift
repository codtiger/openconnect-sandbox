import AppKit
import Foundation
import OpenConnectSandboxCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var profiles: [VPNProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var toolPaths = ToolPaths()
    @Published var errorMessage: String?
    @Published var transientPasswords: [UUID: String] = [:]
    @Published var transientCodes: [UUID: String] = [:]
    @Published private(set) var sessions: [UUID: SupervisorClient] = [:]
    @Published private(set) var isShuttingDown = false

    private let store = ConfigurationStore()
    private let keychain = KeychainStore()
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]

    private init() {
        load()
        writeRuntimeState()
        DispatchQueue.main.async { [weak self] in self?.connectLaunchProfiles() }
    }

    var hasActiveConnections: Bool {
        sessions.values.contains { $0.phase != .stopped && $0.phase != .failed }
    }

    func profile(id: UUID) -> VPNProfile? { profiles.first { $0.id == id } }
    func session(for id: UUID) -> SupervisorClient? { sessions[id] }

    func addProfile() {
        var port = 11080
        let used = Set(profiles.map(\.socksPort))
        while used.contains(port), port < 65535 { port += 1 }
        let profile = VPNProfile(socksPort: port)
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
    }

    func deleteProfile(_ id: UUID) {
        guard sessions[id] == nil else {
            errorMessage = "Disconnect this profile before deleting it."
            return
        }
        profiles.removeAll { $0.id == id }
        try? keychain.removePassword(for: id)
        transientPasswords[id] = nil
        transientCodes[id] = nil
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        persist()
    }

    func duplicateProfile(_ id: UUID) {
        guard var copy = profile(id: id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        copy.connectOnLaunch = false
        var port = copy.socksPort + 1
        let used = Set(profiles.map(\.socksPort))
        while used.contains(port), port < 65535 { port += 1 }
        copy.socksPort = port
        profiles.append(copy)
        selectedProfileID = copy.id
        persist()
    }

    func updateProfile(_ profile: VPNProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    func persist() {
        do {
            try store.save(AppConfiguration(profiles: profiles, toolPaths: toolPaths))
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func redetectTools() {
        let detected = ToolLocator.detect()
        if !detected.openConnect.isEmpty { toolPaths.openConnect = detected.openConnect }
        if !detected.ocproxy.isEmpty { toolPaths.ocproxy = detected.ocproxy }
        if !detected.openConnectSSO.isEmpty { toolPaths.openConnectSSO = detected.openConnectSSO }
        persist()
    }

    func hasSavedPassword(_ id: UUID) -> Bool {
        (try? keychain.password(for: id)) != nil
    }

    func savePassword(for id: UUID) {
        guard let password = transientPasswords[id], !password.isEmpty else {
            errorMessage = "Enter a password before saving it."
            return
        }
        do {
            try keychain.setPassword(password, for: id)
            transientPasswords[id] = ""
        } catch {
            errorMessage = "Could not save the password: \(error.localizedDescription)"
        }
    }

    func forgetPassword(for id: UUID) {
        do { try keychain.removePassword(for: id) }
        catch { errorMessage = "Could not remove the password: \(error.localizedDescription)" }
    }

    func connect(_ id: UUID) {
        guard !isShuttingDown, sessions[id] == nil, let profile = profile(id: id) else { return }
        do {
            try ProfileValidator.validate(profile, allProfiles: profiles)
            try ProfileValidator.validateTools(toolPaths, mode: profile.authenticationMode)
            for port in [profile.socksPort] + profile.localForwards.map(\.localPort) {
                guard PortUtilities.isAvailableOnLoopback(port) else {
                    throw ProfileValidationError.portUnavailable(port)
                }
            }
            let password: String?
            if profile.authenticationMode == .openConnect {
                let savedPassword = try keychain.password(for: id)
                password = nonempty(transientPasswords[id]) ?? savedPassword
            } else {
                password = nil
            }
            let request = SupervisorStartRequest(
                profile: profile,
                toolPaths: toolPaths,
                groupExecPath: helperPath(named: "OpenConnectSandboxExec"),
                ssoBootstrapPath: ssoResourcePath(named: "bootstrap.py"),
                ssoPatchDirectory: ssoResourcePath(named: nil),
                password: password,
                oneTimeCode: profile.authenticationMode == .openConnect ? nonempty(transientCodes[id]) : nil,
                reconnectAttempt: reconnectAttempts[id] ?? 0
            )
            let client = SupervisorClient(profileID: id, socksPort: profile.socksPort)
            client.onExit = { [weak self] client, status, requestedStop in
                self?.supervisorExited(client, status: status, requestedStop: requestedStop)
            }
            client.onStateChange = { [weak self] client in
                guard let self else { return }
                if client.phase == .connected {
                    self.reconnectAttempts[id] = 0
                    self.reconnectTasks[id] = nil
                }
                self.objectWillChange.send()
                self.writeRuntimeState()
            }
            sessions[id] = client
            try client.start(supervisorPath: helperPath(named: "OpenConnectSandboxSupervisor"), request: request)
            transientCodes[id] = ""
            writeRuntimeState()
        } catch {
            sessions[id] = nil
            errorMessage = error.localizedDescription
            writeRuntimeState()
        }
    }

    func disconnect(_ id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts[id] = 0
        sessions[id]?.stop()
        writeRuntimeState()
    }

    func disconnectAll() {
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        sessions.values.forEach { $0.stop() }
        writeRuntimeState()
    }

    func toggle(_ id: UUID) {
        if let session = sessions[id], session.phase != .stopped && session.phase != .failed {
            disconnect(id)
        } else {
            sessions[id] = nil
            connect(id)
        }
    }

    func shutdownAll() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        let active = Array(sessions.values)
        active.forEach { $0.stop() }
        for session in active { await session.waitUntilExit() }
        sessions.removeAll()
        removeRuntimeState()
    }

    func copyEnvironment(for profile: VPNProfile) {
        let text = proxyEnvironmentScript(for: profile)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openShell(for profile: VPNProfile) {
        guard sessions[profile.id]?.phase == .connected else {
            errorMessage = "Connect \(profile.name) before opening its shell."
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenConnectSandbox-\(UUID().uuidString).command")
            let environment = CommandBuilder.shellEnvironment(profile: profile)
            let proxyHelpers = proxyHelperDirectory()
            let script = """
            #!/bin/zsh
            rm -f -- \(CommandBuilder.shellQuote(directory.path))
            export ALL_PROXY=\(CommandBuilder.shellQuote(environment["ALL_PROXY"]!))
            export all_proxy=\(CommandBuilder.shellQuote(environment["all_proxy"]!))
            export HTTP_PROXY=\(CommandBuilder.shellQuote(environment["HTTP_PROXY"]!))
            export HTTPS_PROXY=\(CommandBuilder.shellQuote(environment["HTTPS_PROXY"]!))
            export FTP_PROXY=\(CommandBuilder.shellQuote(environment["FTP_PROXY"]!))
            export http_proxy=\(CommandBuilder.shellQuote(environment["http_proxy"]!))
            export https_proxy=\(CommandBuilder.shellQuote(environment["https_proxy"]!))
            export ftp_proxy=\(CommandBuilder.shellQuote(environment["ftp_proxy"]!))
            export NO_PROXY='localhost,127.0.0.1,::1'
            export no_proxy="$NO_PROXY"
            export VPNCTL_PROFILE_ID=\(CommandBuilder.shellQuote(profile.id.uuidString))
            export VPNCTL_PROXY_URL=\(CommandBuilder.shellQuote(environment["ALL_PROXY"]!))
            export PATH=\(CommandBuilder.shellQuote(proxyHelpers)):"$PATH"
            clear
            echo 'Using \(profile.name.replacingOccurrences(of: "'", with: "")) via \(environment["ALL_PROXY"]!) (ssh/scp/sftp included)'
            exec "${SHELL:-/bin/zsh}" -l
            """
            try Data(script.utf8).write(to: directory, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = "Could not open a terminal: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Could not change Launch at Login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    private func load() {
        do {
            let configuration = try store.load()
            profiles = configuration.profiles
            toolPaths = configuration.toolPaths
            selectedProfileID = profiles.first?.id
            if toolPaths.openConnect.isEmpty || toolPaths.ocproxy.isEmpty { redetectTools() }
        } catch {
            toolPaths = ToolLocator.detect()
            errorMessage = "Could not load settings: \(error.localizedDescription)"
        }
    }

    private func helperPath(named name: String) -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name).path
        return sibling
    }

    private func proxyHelperDirectory() -> String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true).path
    }

    private func proxyEnvironmentScript(for profile: VPNProfile) -> String {
        let environment = CommandBuilder.shellEnvironment(profile: profile)
        let proxy = CommandBuilder.shellQuote(environment["ALL_PROXY"]!)
        let helpers = CommandBuilder.shellQuote(proxyHelperDirectory())
        return """
        if [ -z "${OPENCONNECT_SANDBOX_ORIGINAL_PATH+x}" ]; then export OPENCONNECT_SANDBOX_ORIGINAL_PATH="$PATH"; fi
        export PATH=\(helpers):"$OPENCONNECT_SANDBOX_ORIGINAL_PATH"
        export ALL_PROXY=\(proxy) all_proxy=\(proxy)
        export HTTP_PROXY=\(proxy) HTTPS_PROXY=\(proxy) FTP_PROXY=\(proxy)
        export http_proxy=\(proxy) https_proxy=\(proxy) ftp_proxy=\(proxy)
        export NO_PROXY='localhost,127.0.0.1,::1' no_proxy='localhost,127.0.0.1,::1'
        export VPNCTL_PROFILE_ID=\(CommandBuilder.shellQuote(profile.id.uuidString))
        export VPNCTL_PROXY_URL=\(proxy)
        """
    }

    private func ssoResourcePath(named name: String?) -> String {
        let bundledDirectory = Bundle.main.resourceURL?.appendingPathComponent("SSOPatch", isDirectory: true)
        let developmentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/SSOPatch", isDirectory: true)
        let directory = bundledDirectory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? developmentDirectory
        return name.map { directory.appendingPathComponent($0).path } ?? directory.path
    }

    private func supervisorExited(_ client: SupervisorClient, status: Int32, requestedStop: Bool) {
        let id = client.profileID
        sessions[id] = nil
        writeRuntimeState()
        guard !isShuttingDown, !requestedStop, status != 0,
              let profile = profile(id: id), profile.autoReconnect else { return }
        let attempt = min((reconnectAttempts[id] ?? 0) + 1, 6)
        reconnectAttempts[id] = attempt
        let delay = min(pow(2.0, Double(attempt)), 30.0)
        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect(id)
        }
    }

    private func connectLaunchProfiles() {
        profiles.filter(\.connectOnLaunch).forEach { connect($0.id) }
    }

    private func writeRuntimeState() {
        do {
            try SandboxPaths.ensureDirectory()
            let statuses = sessions.values.map {
                RuntimeProfileStatus(profileID: $0.profileID, phase: $0.phase, supervisorPID: $0.supervisorPID, socksPort: $0.socksPort)
            }
            let state = RuntimeState(appPID: getpid(), profiles: statuses)
            let data = try JSONEncoder.configured.encode(state)
            try data.write(to: SandboxPaths.runtimeURL(), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: SandboxPaths.runtimeURL().path)
        } catch { /* Runtime state is advisory; never fail a connection for it. */ }
    }

    private func removeRuntimeState() { try? FileManager.default.removeItem(at: SandboxPaths.runtimeURL()) }
    private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}
