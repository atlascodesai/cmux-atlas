import Foundation
import Darwin
import SQLite3
#if canImport(MetricKit)
import MetricKit
#endif

struct MemoryDiagnosticsProcessSample: Codable {
    let pid: Int32
    let ppid: Int32
    let tty: String?
    let command: String
    let name: String
    let rssBytes: Int64
    let footprintBytes: Int64?
    let lifetimeMaxFootprintBytes: Int64?
    let cpuTimeNs: UInt64?
    let userTimeNs: UInt64?
    let systemTimeNs: UInt64?
    let cpuPercent: Double?
    let workspaceId: UUID?
    let workspaceTitle: String?
    let panelId: UUID?
    let panelTitle: String?
}

struct MemoryDiagnosticsSamplePayload: Codable {
    let capturedAt: TimeInterval
    let pressureLevel: Int
    let appFootprintBytes: Int64
    let appCPUTimeNs: UInt64?
    let appCPUPercent: Double?
    let trackedTerminalResidentBytes: Int64
    let workspaceResidentBytes: [String: Int64]
    let topPanelConsumers: [MemoryPanelConsumer]
    let processGroups: [MemoryWorkspaceProcessGroup]
    let topSystemProcesses: [MemoryProcessSummary]
    let topDetailedProcesses: [MemoryDiagnosticsProcessSample]
    let systemTotalBytes: Int64
    let systemAvailableBytes: Int64
    let systemSwapUsedBytes: Int64
    let systemCompressedBytes: Int64
}

struct MemoryDiagnosticsIncidentPayload: Codable {
    let reason: String
    let capturedAt: TimeInterval
    let pressureLevel: Int
    let currentSample: MemoryDiagnosticsSamplePayload
    let recentSamples: [MemoryDiagnosticsSamplePayload]
    let recentIncidentSummaries: [MemoryDiagnosticsIncidentRecord]
    let recentMetricPayloads: [MemoryDiagnosticsMetricPayloadRecord]
}

struct MemoryDiagnosticsStoredSample: Codable {
    let id: Int64
    let capturedAt: TimeInterval
    let pressureLevel: Int
    let payload: MemoryDiagnosticsSamplePayload
}

struct MemoryDiagnosticsIncidentRecord: Codable {
    let id: Int64
    let capturedAt: TimeInterval
    let reason: String
    let pressureLevel: Int
    let dumpPath: String?
}

struct MemoryDiagnosticsMetricPayloadRecord: Codable {
    let id: Int64
    let capturedAt: TimeInterval
    let kind: String
    let timeStampBegin: TimeInterval?
    let timeStampEnd: TimeInterval?
    let latestApplicationVersion: String?
    let filePath: String
}

private struct MemoryDiagnosticsIncidentMetadataPayload: Codable {
    let capturedAt: TimeInterval
    let reason: String
    let pressureLevel: Int
    let dumpPath: String?
}

private struct MemoryDiagnosticsManualDumpResult: Codable {
    let ok: Bool
    let path: String
    let capturedAt: TimeInterval
    let pressureLevel: Int
}

final class MemoryDiagnosticsStore {
    static let shared = MemoryDiagnosticsStore()

    private enum RetentionPolicy {
        static let maxSampleRows = 40_000
        static let maxIncidentRows = 400
        static let maxMetricRows = 200
        static let sampleTTL: TimeInterval = 60 * 60 * 48
        static let incidentTTL: TimeInterval = 60 * 60 * 24 * 14
        static let metricTTL: TimeInterval = 60 * 60 * 24 * 30
        static let incidentCooldown: TimeInterval = 45
        static let cleanupEveryNSampleWrites = 40
    }

    private struct ProcessResourceUsageSnapshot {
        let userTimeNs: UInt64
        let systemTimeNs: UInt64
        let cpuTimeNs: UInt64
        let footprintBytes: Int64
        let lifetimeMaxFootprintBytes: Int64?
    }

    private let queue = DispatchQueue(
        label: "com.cmuxterm.memoryDiagnostics",
        qos: .utility
    )
    private var database: OpaquePointer?
    private var didPrepareDatabase = false
    private var sampleWritesSinceCleanup = 0
    private var lastCPUTimeByPID: [Int32: (timestamp: TimeInterval, totalNs: UInt64)] = [:]
    private var lastIncidentCaptureByReason: [String: TimeInterval] = [:]

    private init() {
        queue.async { [weak self] in
            self?.prepareDatabaseIfNeeded()
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func recordSample(
        snapshot: MemoryUsageSnapshot,
        rows: [ProcessTreeRow],
        trackedOwners: [TrackedProcessOwner]
    ) {
        let capturedAt = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareDatabaseIfNeeded()
            let payload = self.makeSamplePayload(
                capturedAt: capturedAt,
                snapshot: snapshot,
                rows: rows,
                trackedOwners: trackedOwners
            )
            self.insertSample(payload)
        }
    }

    func captureIncident(
        reason: String,
        pressureLevel: SystemMemoryPressureLevel,
        source: String
    ) {
        let capturedAt = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            let previousCapture = self.lastIncidentCaptureByReason[reason] ?? 0
            guard capturedAt - previousCapture >= RetentionPolicy.incidentCooldown else {
                return
            }
            self.lastIncidentCaptureByReason[reason] = capturedAt
            self.prepareDatabaseIfNeeded()

            let trackedOwners = MemoryUsageStore.captureTrackedOwnersSnapshot()
            let rows = MemoryUsageStore.loadProcessRows()
            let snapshot = MemoryUsageStore.shared.snapshot
            let currentSample = self.makeSamplePayload(
                capturedAt: capturedAt,
                snapshot: snapshot,
                rows: rows,
                trackedOwners: trackedOwners
            )
            let recentSamples = self.fetchSamplePayloads(limit: 20)
            let recentIncidents = self.fetchIncidents(limit: 10)
            let recentMetricPayloads = self.fetchMetricPayloads(limit: 10)
            let payload = MemoryDiagnosticsIncidentPayload(
                reason: "\(reason):\(source)",
                capturedAt: capturedAt,
                pressureLevel: pressureLevel.rawValue,
                currentSample: currentSample,
                recentSamples: recentSamples,
                recentIncidentSummaries: recentIncidents,
                recentMetricPayloads: recentMetricPayloads
            )

            let dumpURL = self.writeIncidentDump(payload: payload, capturedAt: capturedAt, reason: reason)
            self.insertIncident(
                capturedAt: capturedAt,
                reason: reason,
                pressureLevel: pressureLevel.rawValue,
                dumpPath: dumpURL?.path
            )
        }
    }

    func createManualDump(reason: String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "ERROR: Failed to create memory diagnostics dump"

        let capturedAt = Date().timeIntervalSince1970
        queue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            self.prepareDatabaseIfNeeded()

            let trackedOwners = MemoryUsageStore.captureTrackedOwnersSnapshot()
            let rows = MemoryUsageStore.loadProcessRows()
            let snapshot = MemoryUsageStore.shared.snapshot
            let currentSample = self.makeSamplePayload(
                capturedAt: capturedAt,
                snapshot: snapshot,
                rows: rows,
                trackedOwners: trackedOwners
            )
            let payload = MemoryDiagnosticsIncidentPayload(
                reason: reason,
                capturedAt: capturedAt,
                pressureLevel: snapshot.systemPressureLevel.rawValue,
                currentSample: currentSample,
                recentSamples: self.fetchSamplePayloads(limit: 20),
                recentIncidentSummaries: self.fetchIncidents(limit: 10),
                recentMetricPayloads: self.fetchMetricPayloads(limit: 10)
            )
            guard let dumpURL = self.writeIncidentDump(payload: payload, capturedAt: capturedAt, reason: "manual") else {
                return
            }

            self.insertIncident(
                capturedAt: capturedAt,
                reason: "manual:\(reason)",
                pressureLevel: snapshot.systemPressureLevel.rawValue,
                dumpPath: dumpURL.path
            )

            result = Self.jsonString(
                MemoryDiagnosticsManualDumpResult(
                    ok: true,
                    path: dumpURL.path,
                    capturedAt: capturedAt,
                    pressureLevel: snapshot.systemPressureLevel.rawValue
                )
            )
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    func recentSamplesJSON(limit: Int) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "[]"
        queue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            self.prepareDatabaseIfNeeded()
            let records = self.fetchStoredSamples(limit: limit)
            result = Self.jsonString(records)
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }

    func recentIncidentsJSON(limit: Int) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "[]"
        queue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            self.prepareDatabaseIfNeeded()
            let records = self.fetchIncidents(limit: limit)
            result = Self.jsonString(records)
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }

    func recentMetricPayloadsJSON(limit: Int) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "[]"
        queue.async { [weak self] in
            defer { semaphore.signal() }
            guard let self else { return }
            self.prepareDatabaseIfNeeded()
            let records = self.fetchMetricPayloads(limit: limit)
            result = Self.jsonString(records)
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }

    func archiveMetricPayload(
        kind: String,
        jsonData: Data,
        timeStampBegin: Date?,
        timeStampEnd: Date?,
        latestApplicationVersion: String?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareDatabaseIfNeeded()
            let capturedAt = Date().timeIntervalSince1970
            let payloadURL = self.writeMetricPayload(
                kind: kind,
                jsonData: jsonData,
                capturedAt: capturedAt
            )
            guard let payloadURL else { return }
            self.insertMetricPayload(
                capturedAt: capturedAt,
                kind: kind,
                timeStampBegin: timeStampBegin?.timeIntervalSince1970,
                timeStampEnd: timeStampEnd?.timeIntervalSince1970,
                latestApplicationVersion: latestApplicationVersion,
                filePath: payloadURL.path
            )
        }
    }

    private func makeSamplePayload(
        capturedAt: TimeInterval,
        snapshot: MemoryUsageSnapshot,
        rows: [ProcessTreeRow],
        trackedOwners: [TrackedProcessOwner]
    ) -> MemoryDiagnosticsSamplePayload {
        let processTree = ProcessTreeSnapshot(rows: rows, trackedOwners: trackedOwners)
        let detailedRows = rows
            .filter { $0.residentBytes > 1024 * 1024 }
            .sorted { lhs, rhs in
                if lhs.residentBytes != rhs.residentBytes {
                    return lhs.residentBytes > rhs.residentBytes
                }
                return lhs.command.localizedCaseInsensitiveCompare(rhs.command) == .orderedAscending
            }
            .prefix(40)

        let detailedProcesses = detailedRows.map { row -> MemoryDiagnosticsProcessSample in
            let owner = processTree.resolveOwner(for: row.pid)
            let resourceUsage = Self.queryResourceUsage(for: row.pid)
            return MemoryDiagnosticsProcessSample(
                pid: row.pid,
                ppid: row.ppid,
                tty: row.tty,
                command: row.command,
                name: URL(fileURLWithPath: row.command).lastPathComponent,
                rssBytes: row.residentBytes,
                footprintBytes: resourceUsage?.footprintBytes,
                lifetimeMaxFootprintBytes: resourceUsage?.lifetimeMaxFootprintBytes,
                cpuTimeNs: resourceUsage?.cpuTimeNs,
                userTimeNs: resourceUsage?.userTimeNs,
                systemTimeNs: resourceUsage?.systemTimeNs,
                cpuPercent: estimatedCPUPercent(
                    pid: row.pid,
                    cpuTimeNs: resourceUsage?.cpuTimeNs,
                    capturedAt: capturedAt
                ),
                workspaceId: owner?.workspaceId,
                workspaceTitle: owner?.workspaceTitle,
                panelId: owner?.panelId,
                panelTitle: owner?.panelTitle
            )
        }

        let appUsage = Self.queryResourceUsage(for: getpid())
        let workspaceResidentBytes = Dictionary(
            snapshot.workspaceResidentBytes.map { ($0.key.uuidString, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        return MemoryDiagnosticsSamplePayload(
            capturedAt: capturedAt,
            pressureLevel: snapshot.systemPressureLevel.rawValue,
            appFootprintBytes: snapshot.appFootprintBytes,
            appCPUTimeNs: appUsage?.cpuTimeNs,
            appCPUPercent: estimatedCPUPercent(
                pid: getpid(),
                cpuTimeNs: appUsage?.cpuTimeNs,
                capturedAt: capturedAt
            ),
            trackedTerminalResidentBytes: snapshot.trackedTerminalResidentBytes,
            workspaceResidentBytes: workspaceResidentBytes,
            topPanelConsumers: snapshot.topPanelConsumers,
            processGroups: snapshot.processGroups,
            topSystemProcesses: snapshot.topSystemProcesses,
            topDetailedProcesses: detailedProcesses,
            systemTotalBytes: snapshot.systemTotalBytes,
            systemAvailableBytes: snapshot.systemAvailableBytes,
            systemSwapUsedBytes: snapshot.systemSwapUsedBytes,
            systemCompressedBytes: snapshot.systemCompressedBytes
        )
    }

    private func estimatedCPUPercent(
        pid: Int32,
        cpuTimeNs: UInt64?,
        capturedAt: TimeInterval
    ) -> Double? {
        guard let cpuTimeNs else {
            lastCPUTimeByPID.removeValue(forKey: pid)
            return nil
        }

        defer {
            lastCPUTimeByPID[pid] = (capturedAt, cpuTimeNs)
        }

        guard let previous = lastCPUTimeByPID[pid] else {
            return nil
        }

        let wallDeltaNs = max(1, UInt64((capturedAt - previous.timestamp) * 1_000_000_000))
        guard cpuTimeNs >= previous.totalNs else { return nil }
        let cpuDeltaNs = cpuTimeNs - previous.totalNs
        return (Double(cpuDeltaNs) / Double(wallDeltaNs)) * 100.0
    }

    private static func queryResourceUsage(for pid: Int32) -> ProcessResourceUsageSnapshot? {
        guard pid > 0 else { return nil }

        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let status = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
        guard status == expectedSize else { return nil }

        let userTimeNs = info.pti_total_user
        let systemTimeNs = info.pti_total_system
        return ProcessResourceUsageSnapshot(
            userTimeNs: userTimeNs,
            systemTimeNs: systemTimeNs,
            cpuTimeNs: userTimeNs + systemTimeNs,
            footprintBytes: Int64(info.pti_resident_size),
            lifetimeMaxFootprintBytes: nil
        )
    }

#if DEBUG
    static func debugResourceUsageSnapshotForTesting(pid: Int32) -> (cpuTimeNs: UInt64, footprintBytes: Int64)? {
        guard let snapshot = queryResourceUsage(for: pid) else { return nil }
        return (
            cpuTimeNs: snapshot.cpuTimeNs,
            footprintBytes: snapshot.footprintBytes
        )
    }
#endif

    private func prepareDatabaseIfNeeded() {
        guard !didPrepareDatabase else { return }
        didPrepareDatabase = true

        guard let databaseURL = Self.databaseURL() else { return }
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            return
        }

        self.database = database
        _ = execute(sql: """
            CREATE TABLE IF NOT EXISTS samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at REAL NOT NULL,
                pressure_level INTEGER NOT NULL,
                payload_json TEXT NOT NULL
            );
            """)
        _ = execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_samples_captured_at
            ON samples(captured_at DESC);
            """)
        _ = execute(sql: """
            CREATE TABLE IF NOT EXISTS incidents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at REAL NOT NULL,
                reason TEXT NOT NULL,
                pressure_level INTEGER NOT NULL,
                dump_path TEXT,
                payload_json TEXT NOT NULL
            );
            """)
        _ = execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_incidents_captured_at
            ON incidents(captured_at DESC);
            """)
        _ = execute(sql: """
            CREATE TABLE IF NOT EXISTS metrickit_payloads (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at REAL NOT NULL,
                kind TEXT NOT NULL,
                time_begin REAL,
                time_end REAL,
                latest_version TEXT,
                file_path TEXT NOT NULL
            );
            """)
        _ = execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_metrickit_captured_at
            ON metrickit_payloads(captured_at DESC);
            """)
        cleanupExpiredRecords(force: true)
    }

    private func insertSample(_ payload: MemoryDiagnosticsSamplePayload) {
        let encoded = Self.jsonString(payload)
        guard let database else { return }
        let sql = "INSERT INTO samples (captured_at, pressure_level, payload_json) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, payload.capturedAt)
        sqlite3_bind_int(statement, 2, Int32(payload.pressureLevel))
        Self.bindText(encoded, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }

        sampleWritesSinceCleanup += 1
        if sampleWritesSinceCleanup >= RetentionPolicy.cleanupEveryNSampleWrites {
            sampleWritesSinceCleanup = 0
            cleanupExpiredRecords(force: false)
        }
    }

    private func insertIncident(
        capturedAt: TimeInterval,
        reason: String,
        pressureLevel: Int,
        dumpPath: String?
    ) {
        let payload = Self.jsonString(
            MemoryDiagnosticsIncidentMetadataPayload(
                capturedAt: capturedAt,
                reason: reason,
                pressureLevel: pressureLevel,
                dumpPath: dumpPath
            )
        )
        guard let database else { return }
        let sql = """
            INSERT INTO incidents (captured_at, reason, pressure_level, dump_path, payload_json)
            VALUES (?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, capturedAt)
        Self.bindText(reason, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(pressureLevel))
        if let dumpPath {
            Self.bindText(dumpPath, to: statement, index: 4)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        Self.bindText(payload, to: statement, index: 5)
        _ = sqlite3_step(statement)
        cleanupExpiredRecords(force: false)
    }

    private func insertMetricPayload(
        capturedAt: TimeInterval,
        kind: String,
        timeStampBegin: TimeInterval?,
        timeStampEnd: TimeInterval?,
        latestApplicationVersion: String?,
        filePath: String
    ) {
        guard let database else { return }
        let sql = """
            INSERT INTO metrickit_payloads
            (captured_at, kind, time_begin, time_end, latest_version, file_path)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, capturedAt)
        Self.bindText(kind, to: statement, index: 2)
        if let timeStampBegin {
            sqlite3_bind_double(statement, 3, timeStampBegin)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        if let timeStampEnd {
            sqlite3_bind_double(statement, 4, timeStampEnd)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        if let latestApplicationVersion {
            Self.bindText(latestApplicationVersion, to: statement, index: 5)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        Self.bindText(filePath, to: statement, index: 6)
        _ = sqlite3_step(statement)
        cleanupExpiredRecords(force: false)
    }

    private func fetchStoredSamples(limit: Int) -> [MemoryDiagnosticsStoredSample] {
        guard let database else { return [] }
        let sql = "SELECT id, captured_at, pressure_level, payload_json FROM samples ORDER BY captured_at DESC LIMIT ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 500))))
        var rows: [MemoryDiagnosticsStoredSample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let capturedAt = sqlite3_column_double(statement, 1)
            let pressureLevel = Int(sqlite3_column_int(statement, 2))
            guard let payloadString = Self.columnText(statement, index: 3),
                  let payloadData = payloadString.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(MemoryDiagnosticsSamplePayload.self, from: payloadData) else {
                continue
            }
            rows.append(
                MemoryDiagnosticsStoredSample(
                    id: id,
                    capturedAt: capturedAt,
                    pressureLevel: pressureLevel,
                    payload: payload
                )
            )
        }
        return rows
    }

    private func fetchSamplePayloads(limit: Int) -> [MemoryDiagnosticsSamplePayload] {
        fetchStoredSamples(limit: limit).map(\.payload)
    }

    private func fetchIncidents(limit: Int) -> [MemoryDiagnosticsIncidentRecord] {
        guard let database else { return [] }
        let sql = """
            SELECT id, captured_at, reason, pressure_level, dump_path
            FROM incidents
            ORDER BY captured_at DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 500))))
        var rows: [MemoryDiagnosticsIncidentRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                MemoryDiagnosticsIncidentRecord(
                    id: sqlite3_column_int64(statement, 0),
                    capturedAt: sqlite3_column_double(statement, 1),
                    reason: Self.columnText(statement, index: 2) ?? "",
                    pressureLevel: Int(sqlite3_column_int(statement, 3)),
                    dumpPath: Self.columnText(statement, index: 4)
                )
            )
        }
        return rows
    }

    private func fetchMetricPayloads(limit: Int) -> [MemoryDiagnosticsMetricPayloadRecord] {
        guard let database else { return [] }
        let sql = """
            SELECT id, captured_at, kind, time_begin, time_end, latest_version, file_path
            FROM metrickit_payloads
            ORDER BY captured_at DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 500))))
        var rows: [MemoryDiagnosticsMetricPayloadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                MemoryDiagnosticsMetricPayloadRecord(
                    id: sqlite3_column_int64(statement, 0),
                    capturedAt: sqlite3_column_double(statement, 1),
                    kind: Self.columnText(statement, index: 2) ?? "",
                    timeStampBegin: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3),
                    timeStampEnd: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4),
                    latestApplicationVersion: Self.columnText(statement, index: 5),
                    filePath: Self.columnText(statement, index: 6) ?? ""
                )
            )
        }
        return rows
    }

    private func cleanupExpiredRecords(force: Bool) {
        guard let database else { return }
        let now = Date().timeIntervalSince1970
        let sampleCutoff = now - RetentionPolicy.sampleTTL
        let incidentCutoff = now - RetentionPolicy.incidentTTL
        let metricCutoff = now - RetentionPolicy.metricTTL

        _ = execute(sql: "DELETE FROM samples WHERE captured_at < \(sampleCutoff);")
        _ = execute(sql: "DELETE FROM incidents WHERE captured_at < \(incidentCutoff);")
        _ = execute(sql: "DELETE FROM metrickit_payloads WHERE captured_at < \(metricCutoff);")

        if force || sampleWritesSinceCleanup == 0 {
            _ = execute(sql: """
                DELETE FROM samples
                WHERE id NOT IN (
                    SELECT id FROM samples ORDER BY captured_at DESC LIMIT \(RetentionPolicy.maxSampleRows)
                );
                """)
            _ = execute(sql: """
                DELETE FROM incidents
                WHERE id NOT IN (
                    SELECT id FROM incidents ORDER BY captured_at DESC LIMIT \(RetentionPolicy.maxIncidentRows)
                );
                """)
            _ = execute(sql: """
                DELETE FROM metrickit_payloads
                WHERE id NOT IN (
                    SELECT id FROM metrickit_payloads ORDER BY captured_at DESC LIMIT \(RetentionPolicy.maxMetricRows)
                );
                """)

            sqlite3_exec(database, "VACUUM;", nil, nil, nil)
            pruneDirectory(Self.incidentDirectoryURL())
            pruneDirectory(Self.metricKitDirectoryURL())
        }
    }

    private func execute(sql: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private func writeIncidentDump(
        payload: MemoryDiagnosticsIncidentPayload,
        capturedAt: TimeInterval,
        reason: String
    ) -> URL? {
        guard let directoryURL = Self.incidentDirectoryURL() else { return nil }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: Date(timeIntervalSince1970: capturedAt))
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = directoryURL.appendingPathComponent("\(stamp)-\(sanitizedFileComponent(reason)).json")
            let data = try JSONEncoder.prettyPrinted.encode(payload)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func writeMetricPayload(kind: String, jsonData: Data, capturedAt: TimeInterval) -> URL? {
        guard let directoryURL = Self.metricKitDirectoryURL() else { return nil }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: Date(timeIntervalSince1970: capturedAt))
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = directoryURL.appendingPathComponent("\(stamp)-\(sanitizedFileComponent(kind)).json")
            try jsonData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func pruneDirectory(_ directoryURL: URL?) {
        guard let directoryURL else { return }
        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sorted = fileURLs.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        let excess = sorted.dropFirst(500)
        for url in excess {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        _ = value.withCString { cString in
            sqlite3_bind_text(statement, index, cString, -1, transientDestructor)
        }
    }

    private static func diagnosticsRootURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent(Branding.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    private static func databaseURL(fileManager: FileManager = .default) -> URL? {
        diagnosticsRootURL(fileManager: fileManager)?
            .appendingPathComponent("memory-history.sqlite3", isDirectory: false)
    }

    private static func incidentDirectoryURL(fileManager: FileManager = .default) -> URL? {
        diagnosticsRootURL(fileManager: fileManager)?
            .appendingPathComponent("memory-incidents", isDirectory: true)
    }

    private static func metricKitDirectoryURL(fileManager: FileManager = .default) -> URL? {
        diagnosticsRootURL(fileManager: fileManager)?
            .appendingPathComponent("metrickit", isDirectory: true)
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func sanitizedFileComponent(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? "memory" : candidate
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

#if canImport(MetricKit)
@available(macOS 12.0, *)
final class MemoryMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MemoryMetricKitSubscriber()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let manager = MXMetricManager.shared
        manager.add(self)
        archivePastPayloads(from: manager)
    }

    #if os(iOS) || os(visionOS)
    func didReceive(_ payloads: [MXMetricPayload]) {
        archive(metricPayloads: payloads)
    }
    #endif

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        archive(diagnosticPayloads: payloads)
    }

    private func archivePastPayloads(from manager: MXMetricManager) {
        #if os(iOS) || os(visionOS)
        archive(metricPayloads: manager.pastPayloads)
        #endif
        archive(diagnosticPayloads: manager.pastDiagnosticPayloads)
    }

    #if os(iOS) || os(visionOS)
    private func archive(metricPayloads: [MXMetricPayload]) {
        for payload in metricPayloads {
            MemoryDiagnosticsStore.shared.archiveMetricPayload(
                kind: "metric",
                jsonData: payload.jsonRepresentation(),
                timeStampBegin: payload.timeStampBegin,
                timeStampEnd: payload.timeStampEnd,
                latestApplicationVersion: payload.latestApplicationVersion
            )
        }
    }
    #endif

    private func archive(diagnosticPayloads: [MXDiagnosticPayload]) {
        for payload in diagnosticPayloads {
            MemoryDiagnosticsStore.shared.archiveMetricPayload(
                kind: "diagnostic",
                jsonData: payload.jsonRepresentation(),
                timeStampBegin: payload.timeStampBegin,
                timeStampEnd: payload.timeStampEnd,
                latestApplicationVersion: nil
            )
        }
    }
}
#endif
