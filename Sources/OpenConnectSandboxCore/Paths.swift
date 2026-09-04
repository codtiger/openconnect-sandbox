import Foundation

public enum SandboxPaths {
    public static let directoryName = "OpenConnectSandbox"

    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func configurationURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("profiles.json")
    }

    public static func runtimeURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager).appendingPathComponent("runtime.json")
    }

    public static func ensureDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: applicationSupportDirectory(fileManager: fileManager),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
