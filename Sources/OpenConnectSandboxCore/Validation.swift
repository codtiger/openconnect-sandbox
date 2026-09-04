import Foundation

public enum ProfileValidationError: LocalizedError, Equatable {
    case emptyName
    case invalidServer
    case invalidPort(Int)
    case duplicatePort(Int)
    case portUnavailable(Int)
    case duplicateName(String)
    case invalidForward(String)
    case unsafeArgument(String)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Connection name cannot be empty."
        case .invalidServer: return "Enter a valid VPN server hostname or HTTPS URL."
        case .invalidPort(let port): return "Port \(port) must be between 1024 and 65535 so the connection never requires elevated privileges."
        case .duplicatePort(let port): return "Local port \(port) is used more than once."
        case .portUnavailable(let port): return "Local port \(port) is already in use by another process."
        case .duplicateName(let name): return "Connection names must be unique; ‘\(name)’ is already in use."
        case .invalidForward(let value): return "Invalid local forward: \(value)."
        case .unsafeArgument(let value): return "The extra argument \(value) could bypass isolation and is not allowed."
        case .missingTool(let name): return "The \(name) executable was not found or is not executable."
        }
    }
}

public enum ProfileValidator {
    private static let forbiddenArguments: Set<String> = [
        "--script", "-s", "--script-tun", "-S", "--interface", "-i",
        "--background", "-b", "--pid-file", "--config", "--setuid", "-U",
        "--cookie", "-C", "--cookie-on-stdin", "--passwd-on-stdin",
        "--cookieonly", "--printcookie", "--authenticate", "--servercert",
        "--csd-wrapper", "--force-trojan",
    ]

    public static func validate(_ profile: VPNProfile, allProfiles: [VPNProfile]? = nil) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileValidationError.emptyName
        }
        guard serverIsValid(profile.server) else { throw ProfileValidationError.invalidServer }
        try validatePort(profile.socksPort)

        var usedPorts = Set([profile.socksPort])
        for forward in profile.localForwards {
            try validatePort(forward.localPort)
            try validatePort(forward.remotePort)
            guard !forward.remoteHost.isEmpty,
                  !forward.remoteHost.contains(where: { $0.isWhitespace || $0 == ":" }) else {
                throw ProfileValidationError.invalidForward(forward.remoteHost)
            }
            guard usedPorts.insert(forward.localPort).inserted else {
                throw ProfileValidationError.duplicatePort(forward.localPort)
            }
        }

        if let allProfiles {
            for other in allProfiles where other.id != profile.id {
                if other.name.compare(profile.name, options: .caseInsensitive) == .orderedSame {
                    throw ProfileValidationError.duplicateName(profile.name)
                }
                let otherPorts = Set([other.socksPort] + other.localForwards.map(\.localPort))
                if let duplicate = usedPorts.intersection(otherPorts).first {
                    throw ProfileValidationError.duplicatePort(duplicate)
                }
            }
        }

        for argument in profile.additionalArguments {
            let key = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if forbiddenArguments.contains(key) { throw ProfileValidationError.unsafeArgument(argument) }
            if key.hasPrefix("-"), !key.hasPrefix("--"), key.dropFirst().contains(where: { "bsiSUC".contains($0) }) {
                throw ProfileValidationError.unsafeArgument(argument)
            }
        }
    }

    public static func validateTools(_ paths: ToolPaths, mode: AuthenticationMode) throws {
        guard FileManager.default.isExecutableFile(atPath: paths.openConnect) else {
            throw ProfileValidationError.missingTool("openconnect")
        }
        guard FileManager.default.isExecutableFile(atPath: paths.ocproxy) else {
            throw ProfileValidationError.missingTool("ocproxy")
        }
        if mode == .openConnectSSO,
           !FileManager.default.isExecutableFile(atPath: paths.openConnectSSO) {
            throw ProfileValidationError.missingTool("openconnect-sso")
        }
    }

    private static func validatePort(_ port: Int) throws {
        guard (1024...65535).contains(port) else { throw ProfileValidationError.invalidPort(port) }
    }

    public static func serverIsValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.scheme == "https", components.host != nil,
                  components.user == nil, components.password == nil else { return false }
        } else {
            guard let components = URLComponents(string: "https://\(trimmed)"),
                  components.host != nil, components.user == nil, components.password == nil else { return false }
        }
        return true
    }
}
