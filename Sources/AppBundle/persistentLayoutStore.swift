import AppKit
import Common
import Foundation

// Window placement survives AeroSpace restarts: the tree is saved to disk periodically and restored at startup.
//
// - Same boot session (AeroSpace was restarted, apps kept running): windows are matched by native window id.
// - After a reboot: windows are matched by app bundle id + title, but only for windows that show up shortly after
//   AeroSpace starts (apps reopened at login). Apps launched later open on the focused workspace as usual.

private let saveInterval: Duration = .seconds(10)
private let sameBootRestoreWindow: TimeInterval = 20
private let afterRebootRestoreWindow: TimeInterval = 90
/// If logout is canceled, AeroSpace keeps running; resume saving eventually
private let powerOffSaveFreeze: TimeInterval = 300

private enum MatchBy { case nativeWindowId, title }

private struct PendingRestore {
    let layout: PersistentLayout
    let matchBy: MatchBy
    let deadline: Date
    var claimed: [UInt32: Window] = [:] // saved window id -> live window

    var isExhausted: Bool { Date.now > deadline || claimed.count >= layout.allWorkspaces.flatMap(\.allWindows).count }
}

@MainActor private var pendingRestore: PendingRestore? = nil
@MainActor private var isSavingEnabled = false
@MainActor private var savingFrozenUntil: Date = .distantPast
@MainActor private var lastSavedData: Data? = nil
@MainActor private var titleCache: [UInt32: String] = [:]

private var persistentLayoutDir: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/AeroSpace/")
}
private var persistentLayoutUrl: URL { persistentLayoutDir.appending(component: isDebug ? "layout-debug.json" : "layout.json") }
/// Exists while a restore is in progress. If AeroSpace finds it at startup, the previous restore crashed: don't restore
/// again, otherwise AeroSpace would crash on every start
private var restoreInProgressMarkerUrl: URL {
    persistentLayoutDir.appending(component: isDebug ? "layout-debug.restoring" : "layout.restoring")
}

private func withRestoreInProgressMarker<T>(_ body: () async throws -> T) async rethrows -> T {
    try? FileManager.default.createDirectory(at: persistentLayoutDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: restoreInProgressMarkerUrl.path(percentEncoded: false), contents: nil)
    defer { try? FileManager.default.removeItem(at: restoreInProgressMarkerUrl) }
    return try await body()
}

// MARK: - Startup

/// Must be called before the first (startup) refresh session
@MainActor func loadPersistentLayoutForStartup() {
    if isUnitTest { return }
    if FileManager.default.fileExists(atPath: restoreInProgressMarkerUrl.path(percentEncoded: false)) {
        try? FileManager.default.removeItem(at: restoreInProgressMarkerUrl)
        return
    }
    guard let data = try? Data(contentsOf: persistentLayoutUrl),
          let layout = try? JSONDecoder().decode(PersistentLayout.self, from: data),
          layout.version == PersistentLayout.currentVersion
    else { return }
    lastSavedData = data
    let isSameBoot = layout.bootSessionId == currentBootSessionId && currentBootSessionId != "unknown"
    pendingRestore = PendingRestore(
        layout: layout,
        matchBy: isSameBoot ? .nativeWindowId : .title,
        deadline: Date.now.addingTimeInterval(isSameBoot ? sameBootRestoreWindow : afterRebootRestoreWindow),
    )
}

/// Returns true if a saved layout was found (even if not all of its windows are back yet)
@MainActor func restorePersistentLayoutAtStartup() async throws -> Bool {
    guard var restore = pendingRestore else { return false }
    restore.claimed = try await claimWindows(restore)
    pendingRestore = restore

    let monitors = globalUnsortedMonitorInfos.grouped { $0.rect.topLeftCorner }
    try await withRestoreInProgressMarker { [restore] in
        for savedMonitor in restore.layout.monitors {
            let monitor = monitors[savedMonitor.topLeftCorner]?.singleOrNil()
            for savedWorkspace in savedMonitor.workspaces {
                _ = monitor?.bindWorkspace(Workspace.get(byName: savedWorkspace.name))
                try await restorePersistentWorkspace(savedWorkspace, claimed: restore.claimed)
            }
            _ = monitor?.setVisibleWorkspace(Workspace.get(byName: savedMonitor.visibleWorkspace))
        }
        _ = Workspace.get(byName: restore.layout.focusedWorkspace).focusWorkspace()
    }
    if restore.isExhausted { pendingRestore = nil }
    return true
}

/// Called from every refresh session: restores windows that showed up after startup (slow apps, apps reopened at login)
@MainActor func restorePersistentLayoutForLateWindows() async throws {
    if isStartup { return }
    guard var restore = pendingRestore else { return }
    if restore.isExhausted {
        pendingRestore = nil
        return
    }
    let newlyClaimed = try await claimWindows(restore)
    if newlyClaimed.isEmpty { return }
    restore.claimed.merge(newlyClaimed) { old, _ in old }
    pendingRestore = restore

    let monitors = globalUnsortedMonitorInfos.grouped { $0.rect.topLeftCorner }
    try await withRestoreInProgressMarker { [restore] in
        for savedMonitor in restore.layout.monitors {
            for savedWorkspace in savedMonitor.workspaces where savedWorkspace.allWindows.contains(where: { newlyClaimed[$0.id] != nil }) {
                let workspace = Workspace.get(byName: savedWorkspace.name)
                if !workspace.isVisible { // Don't change what's on the screen under the user's hands
                    _ = monitors[savedMonitor.topLeftCorner]?.singleOrNil()?.bindWorkspace(workspace)
                }
                try await restorePersistentWorkspace(savedWorkspace, claimed: restore.claimed)
            }
        }
    }
}

/// Returns newly claimed windows: saved window id -> live window
@MainActor private func claimWindows(_ restore: PendingRestore) async throws -> [UInt32: Window] {
    let alreadyClaimed = restore.claimed.values.toSet()
    let unclaimedSaved = restore.layout.allWorkspaces.flatMap(\.allWindows).filter { restore.claimed[$0.id] == nil }
    let liveWindows = MacWindow.allWindows.filter { !alreadyClaimed.contains($0) && $0.nodeWorkspace != nil }
    switch restore.matchBy {
        case .nativeWindowId:
            let liveByNativeId = liveWindows.grouped { nativeWindowId($0) }
            var result: [UInt32: Window] = [:]
            for saved in unclaimedSaved {
                if let window = liveByNativeId[saved.id]?.singleOrNil(), window.app.rawAppBundleId == saved.appBundleId {
                    result[saved.id] = window
                }
            }
            return result
        case .title:
            let savedBundleIds = unclaimedSaved.map(\.appBundleId).toSet()
            var candidates: [PersistentLayoutCandidate] = []
            for window in liveWindows where savedBundleIds.contains(window.app.rawAppBundleId) {
                let title = try await window.getTitle(.cancellable)
                candidates.append(PersistentLayoutCandidate(window: window, appBundleId: window.app.rawAppBundleId, title: title))
            }
            return matchPersistentWindowsByTitle(saved: unclaimedSaved, candidates: candidates)
    }
}

// MARK: - Save

@MainActor func startPersistentLayoutSaving() {
    if isUnitTest { return }
    isSavingEnabled = true
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
        Task.startUnstructured { @MainActor in
            // Apps are about to quit (logout/restart/shutdown). Save what we have now, and don't save the
            // shrinking tree while apps close their windows
            await savePersistentLayoutIfChanged()
            savingFrozenUntil = Date.now.addingTimeInterval(powerOffSaveFreeze)
        }
    }
    Task.startUnstructured { @MainActor in
        while true {
            try? await Task.sleep(for: saveInterval)
            await savePersistentLayoutIfChanged()
        }
    }
}

@MainActor private var canSave: Bool {
    if !isSavingEnabled || Date.now < savingFrozenUntil || !TrayMenuModel.shared.isEnabled { return false }
    // AX reports no windows while the screen is locked
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return false }
    if let restore = pendingRestore {
        if !restore.isExhausted { return false } // The file still has windows that we're waiting for
        pendingRestore = nil
    }
    return true
}

@MainActor func savePersistentLayoutIfChanged() async {
    if !canSave { return }
    let windows = Workspace.all.flatMap { $0.allLeafWindowsRecursive }
    for window in windows {
        guard let id = nativeWindowId(window) else { continue }
        if let title = try? await window.getTitle(.nonCancellable) {
            titleCache[id] = title
        }
    }
    if !canSave { return } // Might have changed while awaiting
    writePersistentLayout()
}

/// Synchronous, for the termination handler. Uses titles cached by the last periodic save
@MainActor func savePersistentLayoutBeforeTermination() {
    if !canSave { return }
    writePersistentLayout()
}

@MainActor private func writePersistentLayout() {
    let layout = capturePersistentLayout(bootSessionId: currentBootSessionId, key: nativeWindowId, title: { nativeWindowId($0).flatMap { titleCache[$0] } })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(layout), data != lastSavedData else { return }
    let url = persistentLayoutUrl
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastSavedData = data
    } catch {
        // Best effort. Try again on the next save
    }
}

// MARK: - Util

@MainActor private func nativeWindowId(_ window: Window) -> UInt32? {
    (window as? MacWindow).flatMap { $0.macApp.nativeWindowId(of: $0.windowId) }
}

private let currentBootSessionId: String = {
    var size = 0
    guard unsafe sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard unsafe sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}()
