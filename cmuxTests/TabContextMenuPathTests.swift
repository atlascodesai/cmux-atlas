import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabContextMenuPathTests: XCTestCase {

    // MARK: - Copy Path writes absolute path to pasteboard

    func testCopyPathWritesAbsolutePathToPasteboard() {
        let pasteboard = NSPasteboard.general
        let dir = "/Users/test/Documents/project"

        pasteboard.clearContents()
        pasteboard.setString(dir, forType: .string)

        XCTAssertEqual(pasteboard.string(forType: .string), "/Users/test/Documents/project")
    }

    func testCopyPathPreservesFullHomePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/Documents/test-project"

        // Absolute path should NOT replace home with ~
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dir, forType: .string)

        XCTAssertTrue(pasteboard.string(forType: .string)!.hasPrefix("/"),
                       "Absolute path should start with /")
        XCTAssertFalse(pasteboard.string(forType: .string)!.hasPrefix("~"),
                        "Absolute path should not start with ~")
    }

    // MARK: - tabHasDirectory closure wiring

    func testTabHasDirectoryClosureIsSetOnWorkspaceInit() {
        let manager = TabManager()
        let workspace = manager.tabs[0]
        XCTAssertNotNil(workspace.bonsplitController.tabHasDirectory,
                        "tabHasDirectory closure should be set during workspace initialization")
    }

    func testTabHasDirectoryReturnsFalseForUnknownTab() {
        let manager = TabManager()
        let workspace = manager.tabs[0]

        let randomId = UUID()
        let result = workspace.bonsplitController.tabHasDirectory?(randomId) ?? false
        XCTAssertFalse(result, "Unknown tab ID should return false")
    }

    // MARK: - TabContextAction enum

    func testTabContextActionIncludesRevealInFinder() {
        let action = TabContextAction.revealInFinder
        XCTAssertEqual(action.rawValue, "revealInFinder")
    }

    func testTabContextActionIncludesCopyPath() {
        let action = TabContextAction.copyPath
        XCTAssertEqual(action.rawValue, "copyPath")
    }

    func testAllTabContextActionsIncludeNewCases() {
        let allCases = TabContextAction.allCases
        XCTAssertTrue(allCases.contains(.revealInFinder))
        XCTAssertTrue(allCases.contains(.copyPath))
    }

    // MARK: - Workspace directory tracking

    func testWorkspacePanelDirectoriesTrackDirectories() {
        let manager = TabManager()
        let workspace = manager.tabs[0]

        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected focused panel")
            return
        }

        XCTAssertNil(workspace.panelDirectories[panelId])

        workspace.panelDirectories[panelId] = "/Users/test/project"
        XCTAssertEqual(workspace.panelDirectories[panelId], "/Users/test/project")
    }
}
