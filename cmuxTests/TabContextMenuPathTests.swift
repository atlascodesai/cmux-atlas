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

    func testCopyPathContextActionWritesTrackedDirectoryToPasteboard() {
        let (workspace, tabId, panelId, paneId) = unwrapFirstTerminalContext()
        let pasteboard = NSPasteboard.general
        let directory = "/Users/test/Documents/project"

        workspace.panelDirectories[panelId] = directory
        pasteboard.clearContents()

        workspace.bonsplitController.requestTabContextAction(.copyPath, for: tabId, inPane: paneId)

        XCTAssertEqual(pasteboard.string(forType: .string), directory)
    }

    func testCopyPathPreservesAbsoluteHomePathInsteadOfTildePath() {
        let (workspace, tabId, panelId, paneId) = unwrapFirstTerminalContext()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = home + "/Documents/test-project"
        let pasteboard = NSPasteboard.general

        workspace.panelDirectories[panelId] = directory
        pasteboard.clearContents()

        workspace.bonsplitController.requestTabContextAction(.copyPath, for: tabId, inPane: paneId)

        let copied = try! XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.hasPrefix("/"))
        XCTAssertFalse(copied.hasPrefix("~"))
        XCTAssertEqual(copied, directory)
    }

    func testTabHasDirectoryClosureTracksFocusedTabDirectoryState() {
        let (workspace, tabId, panelId, _) = unwrapFirstTerminalContext()

        XCTAssertFalse(workspace.bonsplitController.tabHasDirectory?(tabId.uuid) ?? true)

        workspace.panelDirectories[panelId] = "/Users/test/project"

        XCTAssertTrue(workspace.bonsplitController.tabHasDirectory?(tabId.uuid) ?? false)
    }

    func testTabHasDirectoryClosureReturnsFalseForUnknownTab() {
        let manager = TabManager()
        let workspace = manager.tabs[0]

        XCTAssertFalse(workspace.bonsplitController.tabHasDirectory?(UUID()) ?? true)
    }

    private func unwrapFirstTerminalContext() -> (Workspace, TabID, UUID, PaneID) {
        let manager = TabManager()
        let workspace = manager.tabs[0]
        let tabId = try! XCTUnwrap(workspace.bonsplitController.allTabIds.first)
        let panelId = try! XCTUnwrap(workspace.panelIdFromSurfaceId(tabId))
        let paneId = try! XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        return (workspace, tabId, panelId, paneId)
    }
}
