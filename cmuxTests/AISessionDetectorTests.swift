import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AISessionDetectorTests: XCTestCase {

    // MARK: - AISessionSnapshot Codable Tests

    func testAISessionSnapshotRoundTrip() throws {
        let session = AISessionSnapshot(
            agentType: .claudeCode,
            sessionId: "abc123-def456",
            workingDirectory: "/Users/test/project",
            command: "claude --dangerously-skip-permissions",
            projectPath: "/Users/test/project",
            lastSeenActive: 1700000000
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AISessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.agentType, .claudeCode)
        XCTAssertEqual(decoded.sessionId, "abc123-def456")
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/project")
        XCTAssertEqual(decoded.command, "claude --dangerously-skip-permissions")
        XCTAssertEqual(decoded.projectPath, "/Users/test/project")
        XCTAssertEqual(decoded.lastSeenActive, 1700000000, accuracy: 0.001)
    }

    func testAISessionSnapshotCodableWithNils() throws {
        let session = AISessionSnapshot(
            agentType: .codex,
            sessionId: nil,
            workingDirectory: nil,
            command: "codex --yolo",
            projectPath: nil,
            lastSeenActive: 1700000000
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AISessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.agentType, .codex)
        XCTAssertNil(decoded.sessionId)
        XCTAssertNil(decoded.workingDirectory)
        XCTAssertEqual(decoded.command, "codex --yolo")
    }

    // MARK: - Resume Command Tests

    func testClaudeCodeResumeCommandWithSessionId() {
        let session = AISessionSnapshot(
            agentType: .claudeCode,
            sessionId: "abc-123",
            workingDirectory: nil,
            command: nil,
            projectPath: nil,
            lastSeenActive: 0
        )
        XCTAssertEqual(session.resumeCommand, "claude --resume abc-123")
    }

    func testClaudeCodeResumeCommandWithoutSessionId() {
        let session = AISessionSnapshot(
            agentType: .claudeCode,
            sessionId: nil,
            workingDirectory: nil,
            command: nil,
            projectPath: nil,
            lastSeenActive: 0
        )
        XCTAssertEqual(session.resumeCommand, "claude --resume")
    }

    func testCodexResumeCommandUsesOriginalCommand() {
        let session = AISessionSnapshot(
            agentType: .codex,
            sessionId: nil,
            workingDirectory: nil,
            command: "codex --yolo",
            projectPath: nil,
            lastSeenActive: 0
        )
        XCTAssertEqual(session.resumeCommand, "codex --yolo")
    }

    func testCodexResumeCommandFallsBackToCodex() {
        let session = AISessionSnapshot(
            agentType: .codex,
            sessionId: nil,
            workingDirectory: nil,
            command: nil,
            projectPath: nil,
            lastSeenActive: 0
        )
        XCTAssertEqual(session.resumeCommand, "codex")
    }

    // MARK: - Panel Snapshot Backward Compatibility

    func testPanelSnapshotDecodesWithoutAISession() throws {
        // Simulate a snapshot from an older version that doesn't have the aiSession field
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789ABC",
            "type": "terminal",
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)

        XCTAssertNil(decoded.aiSession)
        XCTAssertEqual(decoded.type, .terminal)
    }

    func testPanelSnapshotRoundTripWithAISession() throws {
        let aiSession = AISessionSnapshot(
            agentType: .claudeCode,
            sessionId: "test-session-id",
            workingDirectory: "/tmp/test",
            command: "claude --resume",
            projectPath: "/tmp/test",
            lastSeenActive: 1700000000
        )

        let snapshot = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "claude",
            customTitle: nil,
            directory: "/tmp/test",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: "/dev/ttys042",
            terminal: nil,
            browser: nil,
            markdown: nil,
            aiSession: aiSession
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)

        XCTAssertNotNil(decoded.aiSession)
        XCTAssertEqual(decoded.aiSession?.agentType, .claudeCode)
        XCTAssertEqual(decoded.aiSession?.sessionId, "test-session-id")
        XCTAssertEqual(decoded.aiSession?.workingDirectory, "/tmp/test")
    }

    // MARK: - Detect with nil TTY

    func testDetectReturnsNilForNilTTY() {
        let result = AISessionDetector.detect(ttyName: nil, workingDirectory: "/tmp")
        XCTAssertNil(result)
    }

    func testDetectReturnsNilForEmptyTTY() {
        let result = AISessionDetector.detect(ttyName: "", workingDirectory: "/tmp")
        XCTAssertNil(result)
    }

    // MARK: - Agent Type Codable

    func testAgentTypeCodableValues() throws {
        let claudeData = try JSONEncoder().encode(AIAgentType.claudeCode)
        let claudeString = String(data: claudeData, encoding: .utf8)
        XCTAssertEqual(claudeString, "\"claude_code\"")

        let codexData = try JSONEncoder().encode(AIAgentType.codex)
        let codexString = String(data: codexData, encoding: .utf8)
        XCTAssertEqual(codexString, "\"codex\"")
    }
}
