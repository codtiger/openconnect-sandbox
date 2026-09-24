import Foundation

public struct SSOAuthenticationResult: Codable, Sendable {
    public let host: String
    public let cookie: String
    public let fingerprint: String
}

public struct SupervisorStartRequest: Codable, Sendable {
    public var profile: VPNProfile
    public var toolPaths: ToolPaths
    public var groupExecPath: String
    public var ssoBootstrapPath: String?
    public var ssoPatchDirectory: String?
    public var password: String?
    public var oneTimeCode: String?
    public var reconnectAttempt: Int

    public init(profile: VPNProfile, toolPaths: ToolPaths, groupExecPath: String, ssoBootstrapPath: String? = nil, ssoPatchDirectory: String? = nil, password: String?, oneTimeCode: String? = nil, reconnectAttempt: Int = 0) {
        self.profile = profile
        self.toolPaths = toolPaths
        self.groupExecPath = groupExecPath
        self.ssoBootstrapPath = ssoBootstrapPath
        self.ssoPatchDirectory = ssoPatchDirectory
        self.password = password
        self.oneTimeCode = oneTimeCode
        self.reconnectAttempt = reconnectAttempt
    }
}

public struct SupervisorCommand: Codable, Sendable {
    public let command: String
    public init(command: String) { self.command = command }
}

public struct SupervisorEvent: Codable, Sendable {
    public var type: String
    public var phase: ConnectionPhase?
    public var message: String?
    public var exitCode: Int32?

    public init(type: String, phase: ConnectionPhase? = nil, message: String? = nil, exitCode: Int32? = nil) {
        self.type = type
        self.phase = phase
        self.message = message
        self.exitCode = exitCode
    }
}

public enum CommandBuilder {
    public static func ocproxyCommand(profile: VPNProfile, executable: String, pidFilePath: String? = nil) -> String {
        var values = [shellQuote(executable), "-D", String(profile.socksPort)]
        for forward in profile.localForwards {
            values += ["-L", shellQuote("\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)")]
        }
        let proxy = values.joined(separator: " ")
        guard let pidFilePath else { return proxy }
        // OpenConnect evaluates its script through /bin/sh. Recording that
        // shell's PID before exec gives the supervisor ocproxy's stable PID,
        // even if ocproxy moves itself into a separate process group.
        return "umask 077; echo $$ > \(shellQuote(pidFilePath)); exec \(proxy)"
    }

    public static func directArguments(profile: VPNProfile, ocproxyPath: String, hasPassword: Bool, proxyPIDFilePath: String? = nil) -> [String] {
        var values = isolatedBaseArguments(profile: profile, ocproxyPath: ocproxyPath, proxyPIDFilePath: proxyPIDFilePath)
        if !profile.username.isEmpty { values += ["--user", profile.username] }
        if !profile.authGroup.isEmpty { values += ["--authgroup", profile.authGroup] }
        if hasPassword { values.append("--passwd-on-stdin") }
        values += profile.additionalArguments
        values += ["--server", profile.server]
        return values
    }

    public static func ssoArguments(profile: VPNProfile) -> [String] {
        var values = ["--authenticate", "json", "--server", profile.server]
        if !profile.authGroup.isEmpty { values += ["--authgroup", profile.authGroup] }
        if profile.rememberSSOCredentials, !profile.username.isEmpty {
            values += ["--user", profile.username]
        }
        return values
    }

    public static func cookieArguments(profile: VPNProfile, ocproxyPath: String, result: SSOAuthenticationResult, proxyPIDFilePath: String? = nil) -> [String] {
        var values = isolatedBaseArguments(profile: profile, ocproxyPath: ocproxyPath, proxyPIDFilePath: proxyPIDFilePath)
        values += ["--cookie-on-stdin", "--servercert", result.fingerprint]
        values += profile.additionalArguments
        values += ["--server", result.host]
        return values
    }

    public static func proxyURL(port: Int) -> String {
        "socks5h://127.0.0.1:\(port)"
    }

    public static func shellEnvironment(profile: VPNProfile) -> [String: String] {
        let proxy = proxyURL(port: profile.socksPort)
        return [
            "ALL_PROXY": proxy,
            "all_proxy": proxy,
            "HTTP_PROXY": proxy,
            "HTTPS_PROXY": proxy,
            "FTP_PROXY": proxy,
            "http_proxy": proxy,
            "https_proxy": proxy,
            "ftp_proxy": proxy,
            "VPNCTL_PROFILE_ID": profile.id.uuidString,
            "VPNCTL_PROXY_URL": proxy,
        ]
    }

    public static func shellEnvironmentReset() -> String {
        """
        if [ -n "${OPENCONNECT_SANDBOX_ORIGINAL_PATH-}" ]; then export PATH="$OPENCONNECT_SANDBOX_ORIGINAL_PATH"; fi
        unset OPENCONNECT_SANDBOX_ORIGINAL_PATH ALL_PROXY all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY http_proxy https_proxy ftp_proxy NO_PROXY no_proxy VPNCTL_PROFILE_ID VPNCTL_PROXY_URL
        """
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isolatedBaseArguments(profile: VPNProfile, ocproxyPath: String, proxyPIDFilePath: String?) -> [String] {
        [
            "--protocol", profile.vpnProtocol.rawValue,
            "--script-tun",
            "--script", ocproxyCommand(profile: profile, executable: ocproxyPath, pidFilePath: proxyPIDFilePath),
        ]
    }
}
