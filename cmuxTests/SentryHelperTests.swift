import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SentryHelperTests: XCTestCase {
    func testExpectedReleaseNameUsesBundleVersionComponents() {
        let release = SentryLaunchDiagnostics.expectedReleaseName(
            bundleIdentifier: "com.atlascodes.cmux-atlas",
            shortVersion: "0.63.1",
            buildVersion: "97"
        )

        XCTAssertEqual(release, "com.atlascodes.cmux-atlas@0.63.1+97")
    }

    func testExpectedReleaseNameRejectsMissingComponents() {
        XCTAssertNil(
            SentryLaunchDiagnostics.expectedReleaseName(
                bundleIdentifier: "com.atlascodes.cmux-atlas",
                shortVersion: "0.63.1",
                buildVersion: nil
            )
        )
        XCTAssertNil(
            SentryLaunchDiagnostics.expectedReleaseName(
                bundleIdentifier: "  ",
                shortVersion: "0.63.1",
                buildVersion: "97"
            )
        )
    }

    func testDsnHashMatchesKnownAtlasValue() {
        XCTAssertEqual(
            SentryLaunchDiagnostics.dsnHash(dsn: SentryLaunchDiagnostics.atlasDSN),
            "c7cfefe022780ba34d43beeed1c14b7cce0b1361"
        )
    }

    func testScopedCachesDirectoryUsesBundleIdentifierOnMacOS() {
        let cachesDirectory = URL(fileURLWithPath: "/tmp/cmux-caches", isDirectory: true)
        let scoped = SentryLaunchDiagnostics.scopedCachesDirectory(
            bundleIdentifier: "com.atlascodes.cmux-atlas",
            executableName: "cmux Atlas",
            systemCachesDirectory: cachesDirectory,
            isSandboxed: false
        )

        XCTAssertEqual(
            scoped?.path,
            cachesDirectory.appendingPathComponent("com.atlascodes.cmux-atlas", isDirectory: true).path
        )
    }

    func testMatchingLocalSessionFileFindsExpectedRelease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sentry-tests-\(UUID().uuidString)", isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        let sentryStorageDirectory = try XCTUnwrap(
            SentryLaunchDiagnostics.sentryStorageDirectory(
                dsn: SentryLaunchDiagnostics.atlasDSN,
                bundleIdentifier: "com.atlascodes.cmux-atlas",
                executableName: "cmux Atlas",
                cacheDirectoryOverride: cachesDirectory,
                isSandboxed: false
            )
        )
        let matchingDir = sentryStorageDirectory
        let otherDir = cachesDirectory
            .appendingPathComponent("io.sentry", isDirectory: true)
            .appendingPathComponent("other-hash", isDirectory: true)
        try FileManager.default.createDirectory(at: matchingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedRelease = "com.atlascodes.cmux-atlas@0.63.1+97"
        let matchingSession = """
        {"attrs":{"environment":"production","release":"\(expectedRelease)"}}
        """.data(using: .utf8)!
        let otherSession = """
        {"attrs":{"environment":"production","release":"com.atlascodes.cmux-atlas@0.63.1+96"}}
        """.data(using: .utf8)!

        try matchingSession.write(to: matchingDir.appendingPathComponent("session.current"), options: .atomic)
        try otherSession.write(to: otherDir.appendingPathComponent("session.current"), options: .atomic)

        let matched = SentryLaunchDiagnostics.matchingLocalSessionFile(
            expectedReleaseName: expectedRelease,
            sentryStorageDirectory: sentryStorageDirectory,
            cacheDirectoryOverride: cachesDirectory
        )

        XCTAssertEqual(
            matched?.resolvingSymlinksInPath().path,
            matchingDir.appendingPathComponent("session.current").resolvingSymlinksInPath().path
        )
    }

    func testReleaseNameFromSessionDataReadsAttrsRelease() throws {
        let data = """
        {"attrs":{"environment":"production","release":"com.atlascodes.cmux-atlas@0.63.1+97"}}
        """.data(using: .utf8)!

        XCTAssertEqual(
            SentryLaunchDiagnostics.releaseName(fromSessionData: data),
            "com.atlascodes.cmux-atlas@0.63.1+97"
        )
    }

    func testLatestLocalSessionFileReturnsNewestCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sentry-tests-\(UUID().uuidString)", isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        let scopedCachesDirectory = try XCTUnwrap(
            SentryLaunchDiagnostics.cacheDirectoryPath(
                cacheDirectoryOverride: cachesDirectory,
            )
        )
        let sentryRoot = scopedCachesDirectory.appendingPathComponent("io.sentry", isDirectory: true)
        let olderDir = sentryRoot.appendingPathComponent("older", isDirectory: true)
        let newerDir = sentryRoot.appendingPathComponent("newer", isDirectory: true)
        try FileManager.default.createDirectory(at: olderDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: olderDir.appendingPathComponent("session.current"), options: .atomic)
        try Data("{}".utf8).write(to: newerDir.appendingPathComponent("session.current"), options: .atomic)

        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: olderDir.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newerDir.path)

        let latest = SentryLaunchDiagnostics.latestLocalSessionFile(cacheDirectoryOverride: cachesDirectory)

        XCTAssertEqual(
            latest?.resolvingSymlinksInPath().path,
            newerDir.appendingPathComponent("session.current").resolvingSymlinksInPath().path
        )
    }
}
