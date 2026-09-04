import Foundation

public enum AuthenticationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case openConnect = "OpenConnect"
    case openConnectSSO = "OpenConnect SSO"

    public var id: String { rawValue }
}

public enum VPNProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case anyconnect, gp, pulse, nc, f5, fortinet, array
    public var id: String { rawValue }
}

public struct LocalForward: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(id: UUID = UUID(), localPort: Int = 0, remoteHost: String = "", remotePort: Int = 22) {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

public struct VPNProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var authenticationMode: AuthenticationMode
    public var server: String
    public var username: String
    public var authGroup: String
    public var vpnProtocol: VPNProtocol
    public var socksPort: Int
    public var localForwards: [LocalForward]
    public var additionalArguments: [String]
    public var autoReconnect: Bool
    public var connectOnLaunch: Bool

    public init(
        id: UUID = UUID(),
        name: String = "New Connection",
        authenticationMode: AuthenticationMode = .openConnect,
        server: String = "",
        username: String = "",
        authGroup: String = "",
        vpnProtocol: VPNProtocol = .anyconnect,
        socksPort: Int = 11080,
        localForwards: [LocalForward] = [],
        additionalArguments: [String] = [],
        autoReconnect: Bool = false,
        connectOnLaunch: Bool = false
    ) {
        self.id = id
        self.name = name
        self.authenticationMode = authenticationMode
        self.server = server
        self.username = username
        self.authGroup = authGroup
        self.vpnProtocol = vpnProtocol
        self.socksPort = socksPort
        self.localForwards = localForwards
        self.additionalArguments = additionalArguments
        self.autoReconnect = autoReconnect
        self.connectOnLaunch = connectOnLaunch
    }
}

public struct ToolPaths: Codable, Equatable, Sendable {
    public var openConnect: String
    public var ocproxy: String
    public var openConnectSSO: String

    public init(openConnect: String = "", ocproxy: String = "", openConnectSSO: String = "") {
        self.openConnect = openConnect
        self.ocproxy = ocproxy
        self.openConnectSSO = openConnectSSO
    }
}

public struct AppConfiguration: Codable, Sendable {
    public var profiles: [VPNProfile]
    public var toolPaths: ToolPaths

    public init(profiles: [VPNProfile] = [], toolPaths: ToolPaths = ToolPaths()) {
        self.profiles = profiles
        self.toolPaths = toolPaths
    }
}

public enum ConnectionPhase: String, Codable, Sendable {
    case stopped, authenticating, connecting, connected, stopping, failed, reconnecting
}

public struct RuntimeProfileStatus: Codable, Sendable {
    public var profileID: UUID
    public var phase: ConnectionPhase
    public var supervisorPID: Int32?
    public var socksPort: Int
    public var updatedAt: Date

    public init(profileID: UUID, phase: ConnectionPhase, supervisorPID: Int32?, socksPort: Int, updatedAt: Date = Date()) {
        self.profileID = profileID
        self.phase = phase
        self.supervisorPID = supervisorPID
        self.socksPort = socksPort
        self.updatedAt = updatedAt
    }
}

public struct RuntimeState: Codable, Sendable {
    public var appPID: Int32
    public var profiles: [RuntimeProfileStatus]
    public var updatedAt: Date

    public init(appPID: Int32, profiles: [RuntimeProfileStatus], updatedAt: Date = Date()) {
        self.appPID = appPID
        self.profiles = profiles
        self.updatedAt = updatedAt
    }
}
