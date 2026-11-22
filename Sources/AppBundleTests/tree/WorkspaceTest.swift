@testable import AppBundle
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceTest {
    init() { setUpWorkspacesForTests() }

    @Test func testGarbageCollectedWorkspaceIsUnbound() {
        let garbage = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(garbage.parent == nil)
        #expect(Workspace.get(byName: "a") !== garbage)
    }

    @Test func testGarbageCollectAndForceAssignDontDuplicateWorkspaces() {
        config.workspaceToMonitorForceAssignment = ["a": [.main]]
        for _ in 1 ... 3 {
            Workspace.garbageCollectUnusedWorkspaces()
            Workspace.forceAssignWorkspaces()
        }
        let container = mainMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        #expect(container.children.filterIsInstance(of: Workspace.self).count { $0.name == "a" } == 1)
    }

    @Test func testUpdateTrayTextAfterGarbageCollection() {
        _ = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(Workspace.get(byName: "a").focusWorkspace())
        updateTrayText()
        #expect(mainMonitorInfo.visibleWorkspace === globalFocus.workspace)
    }

    @Test func testStaleMonitorInfoResolvesToClosestMonitor() {
        // A MonitorInfo captured before a display (un)plug can point at a monitor that no longer exists. Resolving it
        // used to recurse until the stack overflowed
        let stale = StaleMonitorInfo(rect: Rect(topLeftX: 5000, topLeftY: 0, width: 1920, height: 1080))
        #expect(stale.toMonitorOrRearrangeMonitors() === mainMonitorInfo.toMonitorOrRearrangeMonitors())
        #expect(stale.visibleWorkspace === mainMonitorInfo.visibleWorkspace)
    }
}

private struct StaleMonitorInfo: MonitorInfo {
    let rect: Rect
    var monitorAppKitNsScreenScreensId: Int { 2 }
    var name: String { "Unplugged Monitor" }
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var isMain: Bool { false }
}
