import AppKit
import Common

/// A snapshot of the window tree that is written to disk, so that window placement survives AeroSpace restarts.
///
/// Unlike `FrozenWorld` (in-memory only, see closedWindowsCache), windows are identified by values that outlive the
/// AeroSpace process: the macOS native window id (stable while the app keeps running), and the app bundle id + window
/// title (the fallback after a reboot, when native window ids are reassigned).
struct PersistentLayout: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    /// `kern.bootsessionuuid`. Native window ids are only meaningful within the same boot session
    let bootSessionId: String
    let focusedWorkspace: String
    let monitors: [PersistentMonitor]

    var allWorkspaces: [PersistentWorkspace] { monitors.flatMap(\.workspaces) }
}

struct PersistentMonitor: Codable, Equatable {
    let topLeftX: CGFloat
    let topLeftY: CGFloat
    let visibleWorkspace: String
    let workspaces: [PersistentWorkspace]

    var topLeftCorner: CGPoint { CGPoint(x: topLeftX, y: topLeftY) }
}

struct PersistentWorkspace: Codable, Equatable {
    let name: String
    let rootTilingNode: PersistentContainer
    let floatingWindows: [PersistentWindow]
    let macosUnconventionalWindows: [PersistentWindow]
    /// Most recent first. Replayed on restore so that e.g. tabs/accordion containers show the same window
    let mruWindowIds: [UInt32]

    var allWindows: [PersistentWindow] {
        rootTilingNode.allWindowsRecursive + floatingWindows + macosUnconventionalWindows
    }
}

indirect enum PersistentTreeNode: Codable, Equatable {
    case container(PersistentContainer)
    case window(PersistentWindow)
}

struct PersistentContainer: Codable, Equatable {
    let layout: String
    let orientation: String
    let weight: CGFloat
    let children: [PersistentTreeNode]

    var allWindowsRecursive: [PersistentWindow] {
        children.flatMap {
            switch $0 {
                case .window(let w): [w]
                case .container(let c): c.allWindowsRecursive
            }
        }
    }
}

struct PersistentWindow: Codable, Equatable {
    /// macOS native window id
    let id: UInt32
    let weight: CGFloat
    let appBundleId: String?
    let title: String?
}

// MARK: - Capture

@MainActor
func capturePersistentLayout(
    bootSessionId: String,
    key: (Window) -> UInt32?,
    title: (Window) -> String?,
) -> PersistentLayout {
    PersistentLayout(
        bootSessionId: bootSessionId,
        focusedWorkspace: globalFocus.workspace.name,
        monitors: Monitor.all.sortedBy([\.info.rect.minX, \.info.rect.minY]).map { monitor in
            let container = monitor.getWorkspacesContainerOrCreate()
            return PersistentMonitor(
                topLeftX: monitor.info.rect.topLeftCorner.x,
                topLeftY: monitor.info.rect.topLeftCorner.y,
                visibleWorkspace: container.getVisibleWorkspaceOrCreate(parent: monitor).name,
                workspaces: container.children.filterIsInstance(of: Workspace.self).sorted()
                    .map { captureWorkspace($0, key: key, title: title) },
            )
        },
    )
}

@MainActor
private func captureWorkspace(_ workspace: Workspace, key: (Window) -> UInt32?, title: (Window) -> String?) -> PersistentWorkspace {
    let capture = { (window: Window) -> PersistentWindow? in
        key(window).map {
            PersistentWindow(id: $0, weight: getWeightOrNil(window) ?? 1, appBundleId: window.app.rawAppBundleId, title: title(window))
        }
    }
    return PersistentWorkspace(
        name: workspace.name,
        rootTilingNode: captureContainer(workspace.rootTilingContainer, capture),
        floatingWindows: workspace.floatingWindows.compactMap(capture),
        macosUnconventionalWindows: (
            workspace.macOsNativeHiddenAppsWindowsContainer.children +
                workspace.macOsNativeFullscreenWindowsContainer.children,
        ).filterIsInstance(of: Window.self).compactMap(capture),
        mruWindowIds: mruOrderedWindows(workspace).compactMap(key),
    )
}

@MainActor
private func captureContainer(_ container: TilingContainer, _ capture: (Window) -> PersistentWindow?) -> PersistentContainer {
    PersistentContainer(
        layout: container.layout.rawValue,
        orientation: container.orientation == .h ? "h" : "v",
        weight: getWeightOrNil(container) ?? 1,
        children: container.children.compactMap { child in
            switch child.nodeCases {
                case .window(let w): capture(w).map { .window($0) }
                case .tilingContainer(let c): .container(captureContainer(c, capture))
                default: nil
            }
        },
    )
}

/// Every window of the subtree. For each container, windows under its most recent child come first, then windows
/// under the next most recent child, and so on. Replaying `markAsMostRecentChild` over this list in reverse order
/// reproduces the MRU order of every container
@MainActor
private func mruOrderedWindows(_ node: TreeNode) -> [Window] {
    if let window = node as? Window { return [window] }
    let mru = Array(node._mruChildren)
    let rest = node.children.filter { child in !mru.contains { $0 === child } }
    return (mru + rest.reversed()).flatMap(mruOrderedWindows)
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}

// MARK: - Match

struct PersistentLayoutCandidate {
    let window: Window
    let appBundleId: String?
    let title: String
}

/// Matches live windows to saved windows by app bundle id + exact title. Used after a reboot, when native window ids
/// are meaningless. If several saved windows share the bundle id and title (e.g. terminal windows), they're handed out
/// in saved order: the windows are indistinguishable anyway.
/// Returns saved window id -> live window
func matchPersistentWindowsByTitle(
    saved: [PersistentWindow],
    candidates: [PersistentLayoutCandidate],
) -> [UInt32: Window] {
    var result: [UInt32: Window] = [:]
    for candidate in candidates where !candidate.title.isEmpty {
        if let match = saved.first(where: {
            result[$0.id] == nil && $0.appBundleId == candidate.appBundleId && $0.title == candidate.title
        }) {
            result[match.id] = candidate.window
        }
    }
    return result
}

// MARK: - Restore

/// Rebuilds the workspace's tree from `saved`, with the windows in `claimed` (saved window id -> live window) put back
/// where they were. Saved windows that aren't claimed are skipped. Windows that were already in the workspace's tiling
/// tree but aren't claimed (new windows) stay in the workspace
@MainActor
func restorePersistentWorkspace(_ saved: PersistentWorkspace, claimed: [UInt32: Window]) async throws {
    let workspace = Workspace.get(byName: saved.name)
    let savedIds = saved.allWindows.map(\.id).toSet()
    let ownClaimed = claimed.filter { savedIds.contains($0.key) }
    if ownClaimed.isEmpty { return }

    for frozenWindow in saved.floatingWindows {
        ownClaimed[frozenWindow.id]?.bindAsFloatingWindow(to: workspace)
    }
    for frozenWindow in saved.macosUnconventionalWindows { // Will get fixed by normalizations
        ownClaimed[frozenWindow.id]?.bindAsFloatingWindow(to: workspace)
    }

    let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
    let potentialOrphans = prevRoot.allLeafWindowsRecursive
    prevRoot.unbindFromParent()
    restorePersistentContainer(saved.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST, ownClaimed)
    let claimedWindows = ownClaimed.values.toSet()
    for window in potentialOrphans where !claimedWindows.contains(window) {
        try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
    }

    for id in saved.mruWindowIds.reversed() {
        ownClaimed[id]?.markAsMostRecentChild()
    }
}

@MainActor
private func restorePersistentContainer(_ saved: PersistentContainer, parent: NonLeafTreeNodeObject, index: Int, _ claimed: [UInt32: Window]) {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: saved.weight,
        saved.orientation == "v" ? .v : .h,
        saved.layout.parseLayout() ?? .tiles,
        index: index,
    )
    var index = 0
    for child in saved.children {
        switch child {
            case .window(let w):
                guard let window = claimed[w.id] else { continue }
                window.bind(to: container, adaptiveWeight: w.weight, index: index)
                index += 1
            case .container(let c):
                // Don't create containers that would end up empty
                if !c.allWindowsRecursive.contains(where: { claimed[$0.id] != nil }) { continue }
                restorePersistentContainer(c, parent: container, index: index, claimed)
                index += 1
        }
    }
}
