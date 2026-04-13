import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for atlas-fork-specific features.
final class AtlasFeatureTests: XCTestCase {

    // MARK: - Finder Reveal Extensions

    func testFinderRevealExtensionsContainsArchives() {
        for ext in ["zip", "dmg", "tar", "pkg", "gz", "7z", "rar", "iso"] {
            XCTAssertTrue(
                terminalRevealInFinderExtensions.contains(ext),
                "terminalRevealInFinderExtensions missing archive extension: \(ext)"
            )
        }
    }

    func testFinderRevealExtensionsContainsMedia() {
        for ext in ["png", "jpg", "jpeg", "mp4", "mov", "mp3", "heic"] {
            XCTAssertTrue(
                terminalRevealInFinderExtensions.contains(ext),
                "terminalRevealInFinderExtensions missing media extension: \(ext)"
            )
        }
    }

    // MARK: - Link Resolution

    func testResolvesZipAsLocalFile() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/test.zip"))
        switch target {
        case .localFile(let reference):
            XCTAssertEqual(reference.path, "/tmp/test.zip")
        default:
            XCTFail("Expected .zip path to resolve as .localFile, got \(target)")
        }
    }

    func testResolvesHtmlAsLocalFile() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("./report.html"))
        switch target {
        case .localFile(let reference):
            XCTAssertEqual(reference.path, "./report.html")
        default:
            XCTFail("Expected .html relative path to resolve as .localFile, got \(target)")
        }
    }

    // MARK: - Settings Defaults

    func testAutoResumeOnExitDefaultsToTrue() {
        let defaults = UserDefaults(suiteName: "AtlasFeatureTests-\(UUID().uuidString)")!
        // Empty defaults should return true (the default value)
        XCTAssertTrue(ClaudeCodeIntegrationSettings.autoResumeOnExit(defaults: defaults))
        // Explicitly set to false
        defaults.set(false, forKey: ClaudeCodeIntegrationSettings.autoResumeOnExitKey)
        XCTAssertFalse(ClaudeCodeIntegrationSettings.autoResumeOnExit(defaults: defaults))
    }
}
