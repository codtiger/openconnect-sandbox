import Darwin
import Foundation
import OpenConnectSandboxCore

enum ExitCode {
    static let usage: Int32 = 64
    static let noInput: Int32 = 66
    static let unavailable: Int32 = 69
    static let software: Int32 = 70
    static let tempFailure: Int32 = 75
}

do {
    let context = try Context.load()
    let invocationName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    if ["ssh", "scp", "sftp"].contains(invocationName) {
        guard let selector = ProcessInfo.processInfo.environment["VPNCTL_PROFILE_ID"], !selector.isEmpty else {
            throw CLIError.appNotRunning
        }
        let profile = try context.connectedProfile(selector)
        replaceOpenSSHProcess(
            tool: invocationName,
            arguments: Array(CommandLine.arguments.dropFirst()),
            profile: profile
        )
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw CLIError.usage }
    arguments.removeFirst()

    switch command {
    case "list":
        let json = arguments.contains("--json")
        try list(context: context, json: json)
    case "status":
        guard let selector = arguments.first else { throw CLIError.usage }
        let profile = try context.resolve(selector)
        let status = context.status(for: profile.id)
        printStatus(profile: profile, status: status)
        if status?.phase != .connected { exit(1) }
    case "env":
        guard let selector = arguments.first else { throw CLIError.usage }
        if selector == "--direct" { print(directEnvironment()); exit(0) }
        let profile = try context.connectedProfile(selector)
        print(proxyEnvironment(profile))
    case "shell":
        guard let selector = arguments.first else { throw CLIError.usage }
        arguments.removeFirst()
        var environment: [String: String]? = nil
        if selector == "--direct" { environment = [:] }
        else { environment = CommandBuilder.shellEnvironment(profile: try context.connectedProfile(selector)) }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        replaceProcess(executable: shell, arguments: ["-l"] + arguments.filter { $0 != "--" }, proxyEnvironment: environment)
    case "exec":
        guard let selector = arguments.first else { throw CLIError.usage }
        arguments.removeFirst()
        if arguments.first == "--" { arguments.removeFirst() }
        guard let executable = arguments.first else { throw CLIError.usage }
        arguments.removeFirst()
        let environment: [String: String]?
        if selector == "--direct" { environment = [:] }
        else { environment = CommandBuilder.shellEnvironment(profile: try context.connectedProfile(selector)) }
        replaceProcess(executable: executable, arguments: arguments, proxyEnvironment: environment)
    case "ssh":
        guard let selector = arguments.first else { throw CLIError.usage }
        arguments.removeFirst()
        if arguments.first == "--" { arguments.removeFirst() }
        let profile = try context.connectedProfile(selector)
        replaceOpenSSHProcess(tool: "ssh", arguments: arguments, profile: profile)
    case "help", "--help", "-h":
        printUsage()
    default:
        throw CLIError.usage
    }
} catch let error as CLIError {
    fputs("vpnctl: \(error.description)\n", stderr)
    if case .usage = error { printUsage(toStandardError: true) }
    exit(error.exitCode)
} catch {
    fputs("vpnctl: \(error.localizedDescription)\n", stderr)
    exit(ExitCode.software)
}

private struct Context {
    let configuration: AppConfiguration
    let runtime: RuntimeState?

    static func load() throws -> Context {
        let configuration = try ConfigurationStore().load()
        var runtime: RuntimeState?
        if let data = try? Data(contentsOf: SandboxPaths.runtimeURL()),
           let value = try? JSONDecoder.configured.decode(RuntimeState.self, from: data),
           kill(value.appPID, 0) == 0 {
            runtime = value
        }
        return Context(configuration: configuration, runtime: runtime)
    }

    func resolve(_ selector: String) throws -> VPNProfile {
        if let id = UUID(uuidString: selector), let profile = configuration.profiles.first(where: { $0.id == id }) { return profile }
        let matches = configuration.profiles.filter { $0.name.compare(selector, options: .caseInsensitive) == .orderedSame }
        guard matches.count == 1, let profile = matches.first else { throw CLIError.profileNotFound(selector) }
        return profile
    }

    func status(for id: UUID) -> RuntimeProfileStatus? {
        guard let status = runtime?.profiles.first(where: { $0.profileID == id }) else { return nil }
        if status.phase == .connected {
            guard let pid = status.supervisorPID, kill(pid, 0) == 0,
                  PortUtilities.isSOCKS5Ready(on: status.socksPort) else { return nil }
        }
        return status
    }

    func connectedProfile(_ selector: String) throws -> VPNProfile {
        let profile = try resolve(selector)
        guard runtime != nil else { throw CLIError.appNotRunning }
        guard let status = status(for: profile.id) else { throw CLIError.notConnected(profile.name) }
        switch status.phase {
        case .connected:
            guard let pid = status.supervisorPID, kill(pid, 0) == 0,
                  PortUtilities.isSOCKS5Ready(on: status.socksPort) else {
                throw CLIError.notConnected(profile.name)
            }
            return profile
        case .authenticating, .connecting, .reconnecting, .stopping: throw CLIError.temporary(profile.name, status.phase)
        default: throw CLIError.notConnected(profile.name)
        }
    }
}

private enum CLIError: Error {
    case usage
    case profileNotFound(String)
    case appNotRunning
    case notConnected(String)
    case temporary(String, ConnectionPhase)

    var exitCode: Int32 {
        switch self {
        case .usage: return ExitCode.usage
        case .profileNotFound: return ExitCode.noInput
        case .appNotRunning, .notConnected: return ExitCode.unavailable
        case .temporary: return ExitCode.tempFailure
        }
    }

    var description: String {
        switch self {
        case .usage: return "invalid arguments"
        case .profileNotFound(let value): return "profile ‘\(value)’ was not found or is ambiguous"
        case .appNotRunning: return "OpenConnect Sandbox is not running"
        case .notConnected(let name): return "profile ‘\(name)’ is not connected"
        case .temporary(let name, let phase): return "profile ‘\(name)’ is \(phase.rawValue)"
        }
    }
}

private func list(context: Context, json: Bool) throws {
    if json {
        struct Item: Codable { let id: UUID; let name: String; let type: String; let state: String; let proxy: String? }
        let items = context.configuration.profiles.map { profile in
            let phase = context.status(for: profile.id)?.phase ?? .stopped
            return Item(id: profile.id, name: profile.name, type: profile.authenticationMode.rawValue, state: phase.rawValue,
                        proxy: phase == .connected ? CommandBuilder.proxyURL(port: profile.socksPort) : nil)
        }
        FileHandle.standardOutput.write(try JSONEncoder.configured.encode(items))
        FileHandle.standardOutput.write(Data([0x0A]))
        return
    }
    print("\("NAME".padding(toLength: 22, withPad: " ", startingAt: 0)) \("TYPE".padding(toLength: 17, withPad: " ", startingAt: 0)) \("STATE".padding(toLength: 15, withPad: " ", startingAt: 0)) PROXY")
    for profile in context.configuration.profiles {
        let phase = context.status(for: profile.id)?.phase ?? .stopped
        let proxy = phase == .connected ? CommandBuilder.proxyURL(port: profile.socksPort) : "—"
        print("\(profile.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(profile.authenticationMode.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)) \(phase.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(proxy)")
    }
}

private func printStatus(profile: VPNProfile, status: RuntimeProfileStatus?) {
    let phase = status?.phase ?? .stopped
    print("Profile: \(profile.name)")
    print("Type: \(profile.authenticationMode.rawValue)")
    print("State: \(phase.rawValue)")
    print("Proxy: \(phase == .connected ? CommandBuilder.proxyURL(port: profile.socksPort) : "—")")
    if let pid = status?.supervisorPID { print("Supervisor PID: \(pid)") }
}

private func proxyEnvironment(_ profile: VPNProfile) -> String {
    let proxy = CommandBuilder.proxyURL(port: profile.socksPort)
    let pathSetup: String
    if let helpers = proxyHelperDirectory() {
        pathSetup = """
        if [ -z "${OPENCONNECT_SANDBOX_ORIGINAL_PATH+x}" ]; then export OPENCONNECT_SANDBOX_ORIGINAL_PATH="$PATH"; fi
        export PATH=\(CommandBuilder.shellQuote(helpers)):"$OPENCONNECT_SANDBOX_ORIGINAL_PATH"
        """
    } else {
        pathSetup = ""
    }
    return """
    \(pathSetup)
    export ALL_PROXY=\(CommandBuilder.shellQuote(proxy))
    export all_proxy=\(CommandBuilder.shellQuote(proxy))
    export HTTP_PROXY=\(CommandBuilder.shellQuote(proxy))
    export HTTPS_PROXY=\(CommandBuilder.shellQuote(proxy))
    export FTP_PROXY=\(CommandBuilder.shellQuote(proxy))
    export http_proxy=\(CommandBuilder.shellQuote(proxy))
    export https_proxy=\(CommandBuilder.shellQuote(proxy))
    export ftp_proxy=\(CommandBuilder.shellQuote(proxy))
    export NO_PROXY='localhost,127.0.0.1,::1'
    export no_proxy='localhost,127.0.0.1,::1'
    export VPNCTL_PROFILE_ID=\(CommandBuilder.shellQuote(profile.id.uuidString))
    export VPNCTL_PROXY_URL=\(CommandBuilder.shellQuote(proxy))
    """
}

private func directEnvironment() -> String {
    CommandBuilder.shellEnvironmentReset()
}

private func replaceProcess(executable: String, arguments: [String], proxyEnvironment: [String: String]?) -> Never {
    let proxyKeys = ["ALL_PROXY", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "http_proxy", "https_proxy", "ftp_proxy", "NO_PROXY", "no_proxy", "VPNCTL_PROFILE_ID", "VPNCTL_PROXY_URL"]
    for key in proxyKeys { unsetenv(key) }
    if let proxyEnvironment, !proxyEnvironment.isEmpty {
        for (key, value) in proxyEnvironment { setenv(key, value, 1) }
        setenv("NO_PROXY", "localhost,127.0.0.1,::1", 1)
        setenv("no_proxy", "localhost,127.0.0.1,::1", 1)
        if let proxy = proxyEnvironment["ALL_PROXY"] { setenv("VPNCTL_PROXY_URL", proxy, 1) }
        if let helpers = proxyHelperDirectory() {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            setenv("PATH", helpers + ":" + currentPath, 1)
        }
    }

    var argv = ([executable] + arguments).map { strdup($0) }
    argv.append(nil)
    defer { for pointer in argv where pointer != nil { free(pointer) } }
    execvp(executable, &argv)
    let code: Int32 = errno == ENOENT ? 127 : 126
    fputs("vpnctl: could not execute \(executable): \(String(cString: strerror(errno)))\n", stderr)
    exit(code)
}

private func replaceOpenSSHProcess(tool: String, arguments: [String], profile: VPNProfile) -> Never {
    let proxyCommand = "/usr/bin/nc -x 127.0.0.1:\(profile.socksPort) -X 5 -G 15 %h %p"
    replaceProcess(
        executable: "/usr/bin/\(tool)",
        arguments: ["-o", "ProxyCommand=\(proxyCommand)"] + arguments,
        proxyEnvironment: CommandBuilder.shellEnvironment(profile: profile)
    )
}

private func proxyHelperDirectory() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: helpers.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return nil
    }
    return helpers.path
}

private func printUsage(toStandardError: Bool = false) {
    let text = """
    Usage:
      vpnctl list [--json]
      vpnctl status PROFILE
      vpnctl env PROFILE | --direct
      vpnctl shell PROFILE | --direct [-- SHELL_ARGS...]
      vpnctl exec PROFILE | --direct -- PROGRAM [ARG...]
      vpnctl ssh PROFILE -- [SSH_ARGUMENTS...]
    """
    if toStandardError { fputs(text + "\n", stderr) } else { print(text) }
}
