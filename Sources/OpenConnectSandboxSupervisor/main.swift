import Darwin
import Foundation
import OpenConnectSandboxCore

private let emitter = EventEmitter()

guard let firstLine = readLine(),
      let startData = firstLine.data(using: .utf8),
      let request = try? JSONDecoder.configured.decode(SupervisorStartRequest.self, from: startData) else {
    emitter.send(SupervisorEvent(type: "error", phase: .failed, message: "Invalid supervisor start request."))
    exit(64)
}

private let supervisor = ConnectionSupervisor(request: request, emitter: emitter)
private var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { supervisor.stop(reason: "Supervisor received a termination signal.") }
    source.resume()
    signalSources.append(source)
}
FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
        supervisor.stop(reason: "The application closed its control pipe.")
        return
    }
    guard let text = String(data: data, encoding: .utf8) else { return }
    for line in text.split(separator: "\n") {
        if let data = line.data(using: .utf8),
           let command = try? JSONDecoder.configured.decode(SupervisorCommand.self, from: data),
           command.command == "stop" {
            supervisor.stop(reason: "Stop requested by the application.")
        }
    }
}

signal(SIGPIPE, SIG_IGN)
supervisor.start()
dispatchMain()

private final class EventEmitter {
    private let lock = NSLock()

    func send(_ event: SupervisorEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder.ipc.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private final class GroupProcess {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    private(set) var outputData = Data()
    private let lock = NSLock()
    private let emitter: EventEmitter
    private let captureOutput: Bool

    init(groupExecPath: String, executable: String, arguments: [String], environment: [String: String] = [:], captureOutput: Bool, emitter: EventEmitter) {
        self.emitter = emitter
        self.captureOutput = captureOutput
        process.executableURL = URL(fileURLWithPath: groupExecPath)
        process.arguments = [executable] + arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, capture: captureOutput)
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, capture: false)
        }
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func run() throws { try process.run() }

    func writeSecretLines(_ values: [String]) {
        let data = Data((values.joined(separator: "\n") + "\n").utf8)
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func capturedOutput() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return outputData
    }

    func finishCapturedOutput() -> Data {
        output.fileHandleForReading.readabilityHandler = nil
        let remainder = output.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if outputData.count < 2_000_000 {
            outputData.append(remainder.prefix(2_000_000 - outputData.count))
        }
        let result = outputData
        lock.unlock()
        return result
    }

    func terminateRemainingGroup() {
        let pid = processIdentifier
        guard pid > 1 else { return }
        kill(-pid, SIGTERM)
        usleep(200_000)
        kill(-pid, SIGKILL)
    }

    func stopGracefully(isAuthentication: Bool) {
        let pid = processIdentifier
        guard pid > 0 else { return }
        if isAuthentication {
            kill(-pid, SIGTERM)
        } else {
            // Let OpenConnect log off before terminating ocproxy descendants.
            kill(pid, SIGINT)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(-pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(-pid, SIGKILL)
        }
    }

    private func consume(_ data: Data, capture: Bool) {
        guard !data.isEmpty else { return }
        if capture {
            lock.lock()
            if outputData.count < 2_000_000 {
                outputData.append(data.prefix(2_000_000 - outputData.count))
            }
            lock.unlock()
        } else if let text = String(data: data, encoding: .utf8) {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                emitter.send(SupervisorEvent(type: "log", message: Redactor.redact(line)))
            }
        }
    }
}

private final class ConnectionSupervisor {
    private let request: SupervisorStartRequest
    private let emitter: EventEmitter
    private let lock = NSLock()
    private var activeProcess: GroupProcess?
    private var activeIsAuthentication = false
    private var stopping = false
    private var ssoTemporaryDirectory: URL?
    private var proxyTrackingDirectory: URL?
    private var proxyPIDFileURL: URL?

    init(request: SupervisorStartRequest, emitter: EventEmitter) {
        self.request = request
        self.emitter = emitter
    }

    func start() {
        do {
            try ProfileValidator.validate(request.profile)
            try ProfileValidator.validateTools(request.toolPaths, mode: request.profile.authenticationMode)
            guard FileManager.default.isExecutableFile(atPath: request.groupExecPath) else {
                throw ProfileValidationError.missingTool("process supervisor helper")
            }

            switch request.profile.authenticationMode {
            case .openConnect:
                startDirectTunnel()
            case .openConnectSSO:
                startSSOAuthentication()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop(reason: String) {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        let process = activeProcess
        let isAuthentication = activeIsAuthentication
        lock.unlock()

        emitter.send(SupervisorEvent(type: "state", phase: .stopping, message: reason))
        guard let process, process.isRunning else {
            process?.terminateRemainingGroup()
            finishStopped()
            return
        }
        process.stopGracefully(isAuthentication: isAuthentication)
    }

    private func startDirectTunnel() {
        emitter.send(SupervisorEvent(type: "state", phase: .connecting))
        let hasPassword = !(request.password ?? "").isEmpty
        do {
            let pidFile = try prepareProxyTracking()
            let arguments = CommandBuilder.directArguments(
                profile: request.profile,
                ocproxyPath: request.toolPaths.ocproxy,
                hasPassword: hasPassword,
                proxyPIDFilePath: pidFile
            )
            launchTunnel(arguments: arguments, secret: request.password)
        } catch {
            fail("Could not prepare proxy process tracking: \(error.localizedDescription)")
        }
    }

    private func startSSOAuthentication() {
        emitter.send(SupervisorEvent(type: "state", phase: .authenticating, message: "Complete authentication in the SSO window."))
        guard let bootstrapPath = request.ssoBootstrapPath,
              let patchDirectory = request.ssoPatchDirectory,
              FileManager.default.isReadableFile(atPath: bootstrapPath),
              FileManager.default.fileExists(atPath: patchDirectory) else {
            fail("The ephemeral SSO browser bootstrap is missing.")
        }
        let pythonCommand: (executable: String, arguments: [String])
        do {
            pythonCommand = try Self.pythonCommand(for: request.toolPaths.openConnectSSO, bootstrapPath: bootstrapPath)
        } catch {
            fail("Could not identify openconnect-sso's Python runtime: \(error.localizedDescription)")
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenConnectSandbox-SSO-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            ssoTemporaryDirectory = temporaryDirectory
        } catch {
            fail("Could not create isolated SSO browser storage: \(error.localizedDescription)")
        }
        let process = GroupProcess(
            groupExecPath: request.groupExecPath,
            executable: pythonCommand.executable,
            arguments: pythonCommand.arguments + CommandBuilder.ssoArguments(profile: request.profile),
            environment: [
                "XDG_CONFIG_HOME": temporaryDirectory.appendingPathComponent("config").path,
                "XDG_CACHE_HOME": temporaryDirectory.appendingPathComponent("cache").path,
                "XDG_DATA_HOME": temporaryDirectory.appendingPathComponent("data").path,
                "OPENCONNECT_SANDBOX_EPHEMERAL_SSO": "1",
                "PYTHONPATH": patchDirectory + Self.environmentSuffix(name: "PYTHONPATH", separator: ":"),
                "PATH": URL(fileURLWithPath: request.toolPaths.openConnectSSO).deletingLastPathComponent().path
                    + Self.environmentSuffix(name: "PATH", separator: ":"),
            ],
            captureOutput: true,
            emitter: emitter
        )
        setActive(process, isAuthentication: true)
        process.process.terminationHandler = { [weak self, weak process] task in
            guard let self, let process else { return }
            process.terminateRemainingGroup()
            let authenticationData = process.finishCapturedOutput()
            self.removeSSOTemporaryDirectory()
            if self.isStopping { self.finishStopped(); return }
            guard task.terminationStatus == 0 else {
                self.fail("SSO authentication exited with status \(task.terminationStatus).")
            }
            do {
                let result = try Self.decodeAuthentication(authenticationData)
                let pidFile = try self.prepareProxyTracking()
                let arguments = CommandBuilder.cookieArguments(
                    profile: self.request.profile,
                    ocproxyPath: self.request.toolPaths.ocproxy,
                    result: result,
                    proxyPIDFilePath: pidFile
                )
                self.launchTunnel(arguments: arguments, secret: result.cookie)
            } catch {
                self.fail("Could not read the SSO authentication result: \(error.localizedDescription)")
            }
        }
        do {
            try process.run()
            process.closeInput()
        } catch {
            fail("Could not start openconnect-sso: \(error.localizedDescription)")
        }
    }

    private func launchTunnel(arguments: [String], secret: String?) {
        if isStopping { finishStopped(); return }
        emitter.send(SupervisorEvent(type: "state", phase: .connecting))
        let process = GroupProcess(
            groupExecPath: request.groupExecPath,
            executable: request.toolPaths.openConnect,
            arguments: arguments,
            captureOutput: false,
            emitter: emitter
        )
        setActive(process, isAuthentication: false)
        process.process.terminationHandler = { [weak self, weak process] task in
            guard let self, let process else { return }
            process.terminateRemainingGroup()
            self.terminateTrackedProxy(removeTracking: true)
            if self.isStopping || task.terminationStatus == 0 {
                self.finishStopped()
            } else {
                self.emitter.send(SupervisorEvent(
                    type: "exit",
                    phase: .failed,
                    message: "OpenConnect exited with status \(task.terminationStatus).",
                    exitCode: task.terminationStatus
                ))
                exit(task.terminationStatus)
            }
        }
        do {
            try process.run()
            if let secret, !secret.isEmpty {
                process.writeSecretLines([secret, request.oneTimeCode ?? ""])
            } else {
                process.closeInput()
            }
            waitForProxy(process)
        } catch {
            fail("Could not start OpenConnect: \(error.localizedDescription)")
        }
    }

    private func setActive(_ process: GroupProcess, isAuthentication: Bool) {
        lock.lock()
        activeProcess = process
        activeIsAuthentication = isAuthentication
        lock.unlock()
    }

    private func waitForProxy(_ process: GroupProcess) {
        DispatchQueue.global().async { [weak self, weak process] in
            guard let self, let process else { return }
            for _ in 0..<120 {
                guard process.isRunning, !self.isStopping else { return }
                if PortUtilities.isSOCKS5Ready(on: self.request.profile.socksPort) {
                    self.emitter.send(SupervisorEvent(type: "state", phase: .connected))
                    return
                }
                usleep(250_000)
            }
            guard process.isRunning, !self.isStopping else { return }
            self.emitter.send(SupervisorEvent(type: "error", phase: .failed, message: "The local SOCKS proxy did not become ready."))
            process.stopGracefully(isAuthentication: false)
        }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func finishStopped() {
        terminateTrackedProxy(removeTracking: true)
        removeSSOTemporaryDirectory()
        emitter.send(SupervisorEvent(type: "state", phase: .stopped))
        exit(0)
    }

    private func fail(_ message: String) -> Never {
        terminateTrackedProxy(removeTracking: true)
        removeSSOTemporaryDirectory()
        emitter.send(SupervisorEvent(type: "error", phase: .failed, message: Redactor.redact(message)))
        exit(1)
    }

    private func removeSSOTemporaryDirectory() {
        guard let directory = ssoTemporaryDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
        ssoTemporaryDirectory = nil
    }

    private func prepareProxyTracking() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenConnectSandbox-Proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let pidFile = directory.appendingPathComponent("ocproxy.pid")
        proxyTrackingDirectory = directory
        proxyPIDFileURL = pidFile
        return pidFile.path
    }

    private func terminateTrackedProxy(removeTracking: Bool) {
        if let pidFile = proxyPIDFileURL,
           let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1 {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            usleep(200_000)
            if kill(pid, 0) == 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        guard removeTracking else { return }
        if let directory = proxyTrackingDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        proxyTrackingDirectory = nil
        proxyPIDFileURL = nil
    }

    private static func decodeAuthentication(_ data: Data) throws -> SSOAuthenticationResult {
        if let result = try? JSONDecoder.configured.decode(SSOAuthenticationResult.self, from: data) {
            return try validatedAuthentication(result)
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw CocoaError(.coderReadCorrupt)
        }
        let result = try JSONDecoder.configured.decode(
            SSOAuthenticationResult.self,
            from: Data(text[start...end].utf8)
        )
        return try validatedAuthentication(result)
    }

    private static func validatedAuthentication(_ result: SSOAuthenticationResult) throws -> SSOAuthenticationResult {
        guard ProfileValidator.serverIsValid(result.host), !result.cookie.isEmpty, !result.fingerprint.isEmpty else {
            throw CocoaError(.coderValueNotFound)
        }
        return result
    }

    private static func pythonCommand(for entryPoint: String, bootstrapPath: String) throws -> (executable: String, arguments: [String]) {
        let content = try String(contentsOfFile: entryPoint, encoding: .utf8)
        guard let firstLine = content.split(whereSeparator: \.isNewline).first,
              firstLine.hasPrefix("#!") else { throw CocoaError(.fileReadCorruptFile) }
        let components = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = components.first, executable.hasPrefix("/") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if executable == "/usr/bin/env" {
            guard components.count > 1 else { throw CocoaError(.fileReadCorruptFile) }
            return (executable, Array(components.dropFirst()) + [bootstrapPath])
        }
        return (executable, Array(components.dropFirst()) + [bootstrapPath])
    }

    private static func environmentSuffix(name: String, separator: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return "" }
        return separator + value
    }
}

private enum Redactor {
    static func redact(_ text: String) -> String {
        let lower = text.lowercased()
        let sensitive = ["cookie", "password", "passwd", "token", "authorization:"]
        if sensitive.contains(where: lower.contains) { return "[sensitive output redacted]" }
        return text
    }
}
