import Foundation

public struct ConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL = SandboxPaths.configurationURL()) {
        self.url = url
    }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfiguration(toolPaths: ToolLocator.detect())
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.configured.decode(AppConfiguration.self, from: data)
    }

    public func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.configured.encode(configuration)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public extension JSONEncoder {
    static var configured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var ipc: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum ToolLocator {
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolPaths {
        ToolPaths(
            openConnect: find("openconnect", environment: environment) ?? "",
            ocproxy: find("ocproxy", environment: environment) ?? "",
            openConnectSSO: find("openconnect-sso", environment: environment) ?? ""
        )
    }

    public static func find(_ name: String, environment: [String: String]) -> String? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        if let home = environment["HOME"] {
            directories += [
                "\(home)/.local/bin",
                "\(home)/Library/Python/3.13/bin",
                "\(home)/Library/Python/3.12/bin",
            ]
            if let children = try? FileManager.default.contentsOfDirectory(atPath: home) {
                directories += children.filter { $0.hasPrefix("py") }.map { "\(home)/\($0)/bin" }
            }
        }

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
