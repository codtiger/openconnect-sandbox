import XCTest
@testable import OpenConnectSandboxCore

final class CoreTests: XCTestCase {
    func testIsolatedDirectArguments() throws {
        let profile = VPNProfile(
            name: "Work",
            server: "https://vpn.example.com/group",
            username: "person@example.com",
            authGroup: "employees",
            vpnProtocol: .anyconnect,
            socksPort: 11080
        )
        let arguments = CommandBuilder.directArguments(profile: profile, ocproxyPath: "/opt/homebrew/bin/ocproxy", hasPassword: true)
        XCTAssertTrue(arguments.contains("--script-tun"))
        XCTAssertTrue(arguments.contains("--passwd-on-stdin"))
        XCTAssertFalse(arguments.contains("--background"))
        XCTAssertEqual(arguments.last, profile.server)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--script")! + 1], "'/opt/homebrew/bin/ocproxy' -D 11080")
    }

    func testCookieNeverAppearsInArguments() {
        let profile = VPNProfile(name: "SSO", authenticationMode: .openConnectSSO, server: "vpn.example.com", socksPort: 11081)
        let result = SSOAuthenticationResult(host: "https://vpn.example.com", cookie: "TOP-SECRET", fingerprint: "sha256:abc")
        let arguments = CommandBuilder.cookieArguments(profile: profile, ocproxyPath: "/opt/homebrew/bin/ocproxy", result: result)
        XCTAssertFalse(arguments.contains(where: { $0.contains("TOP-SECRET") }))
        XCTAssertTrue(arguments.contains("--cookie-on-stdin"))
    }

    func testSSOCredentialArgumentsAreOptIn() {
        var profile = VPNProfile(
            name: "SSO",
            authenticationMode: .openConnectSSO,
            server: "vpn.example.com",
            username: "person@example.com",
            socksPort: 11081
        )
        XCTAssertFalse(CommandBuilder.ssoArguments(profile: profile).contains("--user"))
        profile.rememberSSOCredentials = true
        XCTAssertEqual(Array(CommandBuilder.ssoArguments(profile: profile).suffix(2)), ["--user", "person@example.com"])
    }

    func testUnsafeArgumentsAreRejected() {
        for unsafe in ["--script=/tmp/evil", "--config", "-b", "-bq", "--csd-wrapper=/tmp/evil"] {
            let profile = VPNProfile(name: "Unsafe", server: "vpn.example.com", socksPort: 11080, additionalArguments: [unsafe])
            XCTAssertThrowsError(try ProfileValidator.validate(profile))
        }
    }

    func testOptionLikeServerIsRejectedAndServerIsExplicit() throws {
        let injected = VPNProfile(name: "Injected", server: "--config=/tmp/unsafe", socksPort: 11080)
        XCTAssertThrowsError(try ProfileValidator.validate(injected))

        let profile = VPNProfile(name: "Safe", server: "vpn.example.com/group", socksPort: 11080)
        let arguments = CommandBuilder.directArguments(profile: profile, ocproxyPath: "/opt/homebrew/bin/ocproxy", hasPassword: false)
        XCTAssertEqual(Array(arguments.suffix(2)), ["--server", "vpn.example.com/group"])
    }

    func testPortAndNameConflictsAreRejected() {
        let first = VPNProfile(name: "Work", server: "vpn.example.com", socksPort: 11080)
        let duplicateName = VPNProfile(name: "work", server: "vpn2.example.com", socksPort: 11081)
        XCTAssertThrowsError(try ProfileValidator.validate(duplicateName, allProfiles: [first, duplicateName]))

        let lowPort = VPNProfile(name: "Low", server: "vpn.example.com", socksPort: 443)
        XCTAssertThrowsError(try ProfileValidator.validate(lowPort))
    }

    func testShellQuoting() {
        XCTAssertEqual(CommandBuilder.shellQuote("a'b"), "'a'\\''b'")
    }

    func testShellEnvironmentCoversCommonProxyVariables() {
        let profile = VPNProfile(name: "Work", server: "vpn.example.com", socksPort: 12080)
        let environment = CommandBuilder.shellEnvironment(profile: profile)
        for key in ["ALL_PROXY", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "http_proxy", "https_proxy", "ftp_proxy"] {
            XCTAssertEqual(environment[key], "socks5h://127.0.0.1:12080")
        }
        XCTAssertEqual(environment["VPNCTL_PROFILE_ID"], profile.id.uuidString)
    }

    func testProxyPIDTrackingWrapperPreservesIsolation() {
        let profile = VPNProfile(name: "Work", server: "vpn.example.com", socksPort: 12080)
        let command = CommandBuilder.ocproxyCommand(
            profile: profile,
            executable: "/opt/homebrew/bin/ocproxy",
            pidFilePath: "/private/tmp/proxy.pid"
        )
        XCTAssertTrue(command.contains("umask 077"))
        XCTAssertTrue(command.contains("echo $$ > '/private/tmp/proxy.pid'"))
        XCTAssertTrue(command.hasSuffix("exec '/opt/homebrew/bin/ocproxy' -D 12080"))
    }

    func testShellEnvironmentResetRestoresPathAndClearsProfile() {
        let reset = CommandBuilder.shellEnvironmentReset()
        XCTAssertTrue(reset.contains("export PATH=\"$OPENCONNECT_SANDBOX_ORIGINAL_PATH\""))
        XCTAssertTrue(reset.contains("unset OPENCONNECT_SANDBOX_ORIGINAL_PATH"))
        XCTAssertTrue(reset.contains("ALL_PROXY"))
        XCTAssertTrue(reset.contains("VPNCTL_PROFILE_ID"))
    }

    func testConfigurationRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let store = ConfigurationStore(url: url)
        let expected = AppConfiguration(
            profiles: [VPNProfile(name: "Work", server: "vpn.example.com", socksPort: 11080)],
            toolPaths: ToolPaths(openConnect: "/a", ocproxy: "/b", openConnectSSO: "/c")
        )
        try store.save(expected)
        let actual = try store.load()
        XCTAssertEqual(actual.profiles, expected.profiles)
        XCTAssertEqual(actual.toolPaths, expected.toolPaths)
    }

    func testLegacyProfileDefaultsToEphemeralSSO() throws {
        let profile = VPNProfile(name: "Legacy", authenticationMode: .openConnectSSO, server: "vpn.example.com", socksPort: 11080)
        let encoded = try JSONEncoder.configured.encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rememberSSOSession")
        object.removeValue(forKey: "rememberSSOCredentials")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.configured.decode(VPNProfile.self, from: legacy)
        XCTAssertFalse(decoded.rememberSSOSession)
        XCTAssertFalse(decoded.rememberSSOCredentials)
    }

    func testSSOSessionDirectoriesAreProfileScoped() {
        let first = UUID()
        let second = UUID()
        XCTAssertNotEqual(
            SandboxPaths.ssoSessionDirectory(profileID: first),
            SandboxPaths.ssoSessionDirectory(profileID: second)
        )
        XCTAssertTrue(SandboxPaths.ssoSessionDirectory(profileID: first).path.hasSuffix(first.uuidString))
    }
}
