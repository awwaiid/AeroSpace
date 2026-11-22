@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct PersistentLayoutTest {
    init() { setUpWorkspacesForTests() }

    private let key: (Window) -> UInt32? = { UInt32($0.windowId.rawId) }
    private let title: (Window) -> String? = { "title \($0.windowId)" }

    private func capture(_ workspace: Workspace) throws -> PersistentWorkspace {
        let layout = capturePersistentLayout(bootSessionId: "test", key: key, title: title)
        let encoded = try JSONEncoder().encode(layout)
        assertEquals(try JSONDecoder().decode(PersistentLayout.self, from: encoded), layout)
        return try #require(layout.allWorkspaces.first { $0.name == workspace.name })
    }

    private func scatter(_ windows: [Window]) {
        let other = Workspace.get(byName: "other")
        for window in windows {
            window.bind(to: other.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
    }

    @Test func testRestoreRebuildsTreeFloatingWindowsAndSelectedTab() async throws {
        let workspace = Workspace.get(byName: name)
        var tabs: TilingContainer! = nil
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            tabs = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }
        tabs.layout = .tabs
        let floating = TestWindow.new(id: 5, parent: workspace.floatingWindowsContainer)
        assertEquals((tabs.children[1] as! TestWindow).focusWindow(), true) // The selected tab
        assertEquals((workspace.rootTilingContainer.children[0] as! TestWindow).focusWindow(), true)
        let windows = workspace.allLeafWindowsRecursive
        let saved = try capture(workspace)

        scatter(windows)
        assertEquals(workspace.allLeafWindowsRecursive.isEmpty, true)

        try await restorePersistentWorkspace(saved, claimed: Dictionary(uniqueKeysWithValues: windows.map { (UInt32($0.windowId.rawId), $0) }))
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .tabs([.window(2), .window(3), .window(4)])]),
        )
        assertEquals(workspace.floatingWindows, [floating])
        let restoredTabs = try #require(workspace.rootTilingContainer.children[1] as? TilingContainer)
        assertEquals((restoredTabs.mostRecentChild as? Window)?.windowId, 3)
        assertEquals(workspace.mostRecentWindowRecursive?.windowId, 1)
    }

    @Test func testRestoreSkipsClosedWindowsAndKeepsNewWindows() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 4, parent: $0)
            }
        }
        let windows = Dictionary(uniqueKeysWithValues: workspace.allLeafWindowsRecursive.map { (UInt32($0.windowId.rawId), $0) })
        let saved = try capture(workspace)

        scatter(Array(windows.values))
        windows[2]!.unbindFromParent() // Closed while AeroSpace was down
        windows[4]!.unbindFromParent() // Closed while AeroSpace was down
        let newWindow = TestWindow.new(id: 5, parent: workspace.rootTilingContainer) // Opened while AeroSpace was down

        try await restorePersistentWorkspace(saved, claimed: windows.filter { $0.key != 2 && $0.key != 4 })
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(), [1, 3, 5])
        assertEquals((windows[3]!.parent as? TilingContainer)?.orientation, .v) // Its container is back
        // No empty container for 4
        assertEquals(workspace.rootTilingContainer.allContainersRecursive.count(where: { $0.children.isEmpty }), 0)
        assertEquals(newWindow.nodeWorkspace, workspace)
    }

    @Test func testRestoreDoesNothingWithoutClaimedWindows() async throws {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let saved = try capture(workspace)
        let root = workspace.rootTilingContainer

        try await restorePersistentWorkspace(saved, claimed: [:])
        assertEquals(workspace.rootTilingContainer === root, true)
    }

    @Test func testMatchByTitle() {
        let workspace = Workspace.get(byName: name)
        let windows = (1 ... 5).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: workspace.rootTilingContainer) }
        let saved = [
            PersistentWindow(id: 10, weight: 1, appBundleId: "term", title: "~"),
            PersistentWindow(id: 11, weight: 1, appBundleId: "term", title: "~"),
            PersistentWindow(id: 12, weight: 1, appBundleId: "browser", title: "News"),
            PersistentWindow(id: 13, weight: 1, appBundleId: "term", title: ""),
        ]
        let candidates = [
            PersistentLayoutCandidate(window: windows[0], appBundleId: "term", title: "~"),
            PersistentLayoutCandidate(window: windows[1], appBundleId: "other", title: "News"), // Different app
            PersistentLayoutCandidate(window: windows[2], appBundleId: "term", title: ""), // Title not known yet
            PersistentLayoutCandidate(window: windows[3], appBundleId: "browser", title: "News"),
            PersistentLayoutCandidate(window: windows[4], appBundleId: "term", title: "~"),
        ]
        let result = matchPersistentWindowsByTitle(saved: saved, candidates: candidates).mapValues(\.windowId)
        assertEquals(result, [10: 1, 11: 5, 12: 4])
    }
}

extension TilingContainer {
    @MainActor fileprivate var allContainersRecursive: [TilingContainer] {
        [self] + children.filterIsInstance(of: TilingContainer.self).flatMap(\.allContainersRecursive)
    }
}
