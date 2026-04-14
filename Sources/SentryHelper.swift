import Foundation
import CryptoKit
import Sentry
#if canImport(AppKit)
import AppKit
#endif

struct SentryLaunchCheckRecord: Codable, Equatable {
    var timestamp: TimeInterval
    var trigger: String?
    var attempt: Int?
    var telemetryEnabled: Bool
    var environment: String
    var bundleIdentifier: String?
    var executableName: String?
    var cacheDirectoryPath: String?
    var shortVersion: String?
    var buildVersion: String?
    var dsnHash: String?
    var scopedCachesDirectory: String?
    var installationPath: String?
    var installationExists: Bool?
    var expectedLocalSessionPath: String?
    var expectedLocalSessionExists: Bool?
    var expectedLocalEnvelopesPath: String?
    var localEnvelopeCount: Int?
    var expectedReleaseName: String?
    var observedLocalSessionPath: String?
    var observedLocalSessionRelease: String?
    var matchedLocalSessionPath: String?
    var matchedLocalSessionRelease: String?
}

enum SentryLaunchDiagnostics {
    static let launchCheckFilename = "sentry-launch-check.json"
    static let launchCheckDelay: TimeInterval = 1.5
    static let launchCheckRetryCount = 4
    static let launchCheckRetryInterval: TimeInterval = 1.5
    static let atlasDSN = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"

    static func runtimeEnvironment() -> String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    static func expectedReleaseName(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        shortVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        buildVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) -> String? {
        guard let bundleIdentifier = normalizedComponent(bundleIdentifier),
              let shortVersion = normalizedComponent(shortVersion),
              let buildVersion = normalizedComponent(buildVersion) else {
            return nil
        }
        return "\(bundleIdentifier)@\(shortVersion)+\(buildVersion)"
    }

    static func normalizedComponent(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func releaseName(fromSessionData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attrs = json["attrs"] as? [String: Any] else {
            return nil
        }
        return attrs["release"] as? String
    }

    static func cacheDirectoryPath(
        cacheDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        cacheDirectoryOverride ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    static func dsnHash(dsn: String?) -> String? {
        guard let dsn = normalizedComponent(dsn) else {
            return nil
        }
        guard let data = dsn.data(using: .utf8) else {
            return nil
        }

        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func scopedCachesDirectory(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        systemCachesDirectory: URL? = nil,
        isSandboxed: Bool? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let cachesDirectory = systemCachesDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        #if os(macOS)
        let sandboxed = isSandboxed ?? (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        if sandboxed {
            return cachesDirectory
        }

        guard let identifier = normalizedComponent(bundleIdentifier) ?? normalizedComponent(executableName) else {
            return nil
        }
        return cachesDirectory.appendingPathComponent(identifier, isDirectory: true)
        #else
        return cachesDirectory
        #endif
    }

    static func sentryStorageDirectory(
        dsn: String? = atlasDSN,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        cacheDirectoryOverride: URL? = nil,
        isSandboxed: Bool? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let cacheDirectoryPath = cacheDirectoryPath(
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        ),
        let dsnHash = dsnHash(dsn: dsn) else {
            return nil
        }

        return cacheDirectoryPath
            .appendingPathComponent("io.sentry", isDirectory: true)
            .appendingPathComponent(dsnHash, isDirectory: true)
    }

    static func installationFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        cacheDirectoryOverride: URL? = nil,
        isSandboxed: Bool? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        cacheDirectoryPath(
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        )?.appendingPathComponent("INSTALLATION", isDirectory: false)
    }

    static func localEnvelopeCount(
        sentryStorageDirectory: URL?,
        fileManager: FileManager = .default
    ) -> Int {
        guard let envelopesDirectory = sentryStorageDirectory?.appendingPathComponent("envelopes", isDirectory: true),
              let entries = try? fileManager.contentsOfDirectory(at: envelopesDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.count
    }

    static func matchingLocalSessionFile(
        expectedReleaseName: String,
        sentryStorageDirectory: URL? = nil,
        cacheDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in localSessionCandidates(
            sentryStorageDirectory: sentryStorageDirectory,
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        ) {
            guard let data = try? Data(contentsOf: candidate),
                  releaseName(fromSessionData: data) == expectedReleaseName else {
                continue
            }
            return candidate
        }

        return nil
    }

    static func latestLocalSessionFile(
        sentryStorageDirectory: URL? = nil,
        cacheDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        localSessionCandidates(
            sentryStorageDirectory: sentryStorageDirectory,
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        ).first
    }

    private static func localSessionCandidates(
        sentryStorageDirectory: URL? = nil,
        cacheDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        if let sentryStorageDirectory {
            let expectedPath = sentryStorageDirectory.appendingPathComponent("session.current", isDirectory: false)
            return fileManager.fileExists(atPath: expectedPath.path) ? [expectedPath] : []
        }

        guard let cachesDirectory = cacheDirectoryOverride ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return []
        }

        let sentryRoot = cachesDirectory.appendingPathComponent("io.sentry", isDirectory: true)
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: sentryRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        return sortedCandidates.map {
            $0.appendingPathComponent("session.current", isDirectory: false)
        }.filter {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    static func launchCheckFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        guard let snapshotURL = SessionPersistenceStore.defaultSnapshotFileURL(
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ) else {
            return nil
        }
        return snapshotURL.deletingLastPathComponent().appendingPathComponent(launchCheckFilename, isDirectory: false)
    }

    static func writeLaunchCheckRecord(
        _ record: SentryLaunchCheckRecord,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let fileURL = launchCheckFileURL(bundleIdentifier: bundleIdentifier, appSupportDirectory: appSupportDirectory) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    static func scheduleLaunchCheck(
        telemetryEnabled: Bool,
        bundle: Bundle = .main,
        appSupportDirectory: URL? = nil,
        cacheDirectoryOverride: URL? = nil,
        dsn: String = atlasDSN,
        fileManager: FileManager = .default,
        delay: TimeInterval = launchCheckDelay,
        queue: DispatchQueue = .global(qos: .utility)
    ) {
        let bundleIdentifier = bundle.bundleIdentifier
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let expectedReleaseName = expectedReleaseName(
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
        let environment = runtimeEnvironment()
        let systemCachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cacheDirectoryPath = cacheDirectoryPath(
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        )
        let scopedCachesDirectory = scopedCachesDirectory(
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            systemCachesDirectory: systemCachesDirectory,
            fileManager: fileManager
        )
        let dsnHash = dsnHash(dsn: dsn)
        let sentryStorageDirectory = sentryStorageDirectory(
            dsn: dsn,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        )
        let installationURL = installationFileURL(
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            cacheDirectoryOverride: cacheDirectoryOverride,
            fileManager: fileManager
        )
        let expectedSessionURL = sentryStorageDirectory?.appendingPathComponent("session.current", isDirectory: false)
        let envelopesURL = sentryStorageDirectory?.appendingPathComponent("envelopes", isDirectory: true)

        func captureRecord(trigger: String, attempt: Int) {
            let observedSessionURL = latestLocalSessionFile(
                sentryStorageDirectory: sentryStorageDirectory,
                cacheDirectoryOverride: cacheDirectoryOverride,
                fileManager: fileManager
            )
            let observedRelease: String?
            if let observedSessionURL,
               let data = try? Data(contentsOf: observedSessionURL) {
                observedRelease = releaseName(fromSessionData: data)
            } else {
                observedRelease = nil
            }
            let matchedSessionURL = expectedReleaseName.flatMap {
                matchingLocalSessionFile(
                    expectedReleaseName: $0,
                    sentryStorageDirectory: sentryStorageDirectory,
                    cacheDirectoryOverride: cacheDirectoryOverride,
                    fileManager: fileManager
                )
            }
            let matchedRelease: String?
            if let matchedSessionURL,
               let data = try? Data(contentsOf: matchedSessionURL) {
                matchedRelease = releaseName(fromSessionData: data)
            } else {
                matchedRelease = nil
            }
            let record = SentryLaunchCheckRecord(
                timestamp: Date().timeIntervalSince1970,
                trigger: trigger,
                attempt: attempt,
                telemetryEnabled: telemetryEnabled,
                environment: environment,
                bundleIdentifier: bundleIdentifier,
                executableName: executableName,
                cacheDirectoryPath: cacheDirectoryPath?.path,
                shortVersion: shortVersion,
                buildVersion: buildVersion,
                dsnHash: dsnHash,
                scopedCachesDirectory: scopedCachesDirectory?.path,
                installationPath: installationURL?.path,
                installationExists: installationURL.map { fileManager.fileExists(atPath: $0.path) },
                expectedLocalSessionPath: expectedSessionURL?.path,
                expectedLocalSessionExists: expectedSessionURL.map { fileManager.fileExists(atPath: $0.path) },
                expectedLocalEnvelopesPath: envelopesURL?.path,
                localEnvelopeCount: localEnvelopeCount(sentryStorageDirectory: sentryStorageDirectory, fileManager: fileManager),
                expectedReleaseName: expectedReleaseName,
                observedLocalSessionPath: observedSessionURL?.path,
                observedLocalSessionRelease: observedRelease,
                matchedLocalSessionPath: matchedSessionURL?.path,
                matchedLocalSessionRelease: matchedRelease
            )
            writeLaunchCheckRecord(
                record,
                bundleIdentifier: bundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )

            guard telemetryEnabled,
                  let expectedReleaseName,
                  matchedRelease != expectedReleaseName else {
                return
            }

            NSLog(
                "sentry.launch.check missing_local_session trigger=%@ attempt=%ld expectedRelease=%@ matchedRelease=%@ path=%@",
                trigger,
                attempt,
                expectedReleaseName,
                matchedRelease ?? "nil",
                matchedSessionURL?.path ?? "nil"
            )
        }

        func scheduleCaptureSeries(trigger: String, initialDelay: TimeInterval) {
            let retryCount = max(1, launchCheckRetryCount)
            for attempt in 1...retryCount {
                let attemptDelay = initialDelay + (Double(attempt - 1) * launchCheckRetryInterval)
                queue.asyncAfter(deadline: .now() + attemptDelay) {
                    captureRecord(trigger: trigger, attempt: attempt)
                }
            }
        }

        scheduleCaptureSeries(trigger: "startup", initialDelay: delay)

        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            scheduleCaptureSeries(trigger: "didBecomeActive", initialDelay: delay)
        }
        #endif
    }
}

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

private func sentryCaptureMessage(
    _ message: String,
    level: SentryLevel,
    category: String,
    data: [String: Any]?,
    contextKey: String?
) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(level)
        scope.setTag(value: category, key: "category")
        if let data {
            scope.setContext(value: data, key: contextKey ?? category)
        }
    }
}

func sentryCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .warning, category: category, data: data, contextKey: contextKey)
}

func sentryCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .error, category: category, data: data, contextKey: contextKey)
}
