---
name: maintain-fork
description: How awwaiid's AeroSpace fork (branch custom-build) is kept in sync with upstream nikitabobko/AeroSpace and vadika's tabs/scrolling layout branch, how to rebuild/install it, and what to watch out for. Use when asked to update/resync with upstream, rebase the custom build, add a local patch, or rebuild and install AeroSpace from this repo.
---

# Maintaining the `custom-build` fork

## Shape of the fork

```
upstream/main (nikitabobko/AeroSpace)          <- the original project
   └── vadika/codex/tabs-layout                <- scrolling + tabs layouts (upstream PR #2057), rebased by vadika
         └── our commits, cherry-picked        <- branch `custom-build` (default branch of origin)
```

Remotes:
- `origin`   = git@github.com:awwaiid/AeroSpace.git (ours; `custom-build` is the default branch)
- `upstream` = git@github.com:nikitabobko/AeroSpace.git (the original)
- `vadika`   = https://github.com/vadika/AeroSpace.git (branch `codex/tabs-layout`; add it if missing)

The branch is **rebuilt, not merged**: base = vadika's branch tip, then our commits are cherry-picked on top.
vadika periodically rebases onto upstream main, so taking vadika's tip is how we pick up upstream. We do not
merge upstream/main on top: upstream main moves fast (big in-flight refactors like "Native tabs WIP n/m"), and
vadika's branch is the tested combination. The exception is small, clearly-bug-fixing upstream commits that landed
after vadika's base. Backport those with `git cherry-pick -x` as the first commits above the base. Example:
the two `getWindowLevel` fixes (0d498deb, 7a3f2e34).

The README note at the top of README.md lists every local change. Keep it current: it is one of our commits.

## Resync procedure

1. `git fetch upstream && git fetch vadika codex/tabs-layout && git fetch origin`
2. See what's new:
   - `git log --oneline <old-vadika-tip>..vadika/codex/tabs-layout` (find the old tip: `git merge-base custom-build vadika/codex/tabs-layout`)
   - `git log --oneline $(git merge-base vadika/codex/tabs-layout upstream/main)..upstream/main` = upstream commits
     vadika doesn't have yet. Skim them for bug fixes worth backporting (crashes, focus, AX handling); skip
     build/CI/docs churn.
3. Back up: `git branch backup/custom-build-$(date +%F) custom-build`
4. Rebuild: `git checkout -B custom-build vadika/codex/tabs-layout`, then backports (`cherry-pick -x`), then
   `git cherry-pick` our commits in their original order (`git log --reverse --oneline vadika-old-tip..backup/...`).
5. Expect conflicts from upstream renames. Seen so far: `activeWorkspace`→`visibleWorkspace`,
   `setActiveWorkspace`→`setVisibleWorkspace`, `workspaceMonitor`→`workspaceMonitorInfo`, `focus`→`globalFocus`,
   `monitorInfos`→`globalUnsortedMonitorInfos`, `Monitor`→`MonitorInfo` (and `Monitor` is now a TreeNode),
   `MonitorEx.swift`→`MonitorInfoEx.swift`, and tests moved from XCTest to Swift Testing: add `@Test` to
   cherry-picked test funcs. Fold API-rename fixes into the commit they belong to (`git commit --fixup=<sha>`, then
   `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash vadika/codex/tabs-layout`) so each local change stays one commit.
   Drop commits that upstream made obsolete, and say so in the README note.
6. Build and test (see below). All tests must pass.
7. Force-push: `git push --force-with-lease origin custom-build`. **Ask Brock first**: it rewrites the fork's default branch.

## Build, test, install on this machine

- Toolchain: upstream requires **swiftly** (installed via brew, `swiftly init --no-modify-profile`). The pinned
  version is in `.swift-version` (`swiftly install <ver>` after a bump).
- asdf shims (bundler/cargo) need the real PATH, so scripts run with `NUKE_PATH=1`. But `NUKE_PATH=1` also skips
  setup.sh's swiftly wrapper, so put swiftly's toolchain on PATH yourself:
  ```
  export PATH="$(swiftly use --print-location)/usr/bin:$PATH" NUKE_PATH=1
  ./build-debug.sh            # quick compile check
  ./swift-test.sh             # full test suite; single: swift test --filter Suite/testName
  ./format.sh                 # must leave no diff
  ./build-release.sh          # needs the aerospace-codesign-certificate identity
  ./install-from-sources.sh --dont-rebuild
  ```
- `.tool-versions` (untracked) pins ruby/bundler/rust for asdf.
- Weird SwiftPM errors after a resync (e.g. "enables traits ... on package 'swift-collections' that declares no
  traits") mean stale package checkouts: `swift package reset` for SwiftPM, and
  `rm -rf xcode/.xcode-build/SourcePackages` for the xcodebuild side.
- build-release.sh aborts on a dirty tree (`check-uncommitted-files.sh`), and it regenerates
  `xcode/AeroSpace.xcodeproj`, so commit everything first.
- Installing updates the CLI only. The running server needs a restart (layout is restored from `layout.json`, but
  still **ask before**):
  `osascript -e 'quit app "AeroSpace"'; open -a AeroSpace`

## Debugging tips that paid off

- Crashes: `~/Library/Logs/DiagnosticReports/AeroSpace-*.ips` (JSON after the first line; the faulting thread's
  frames have symbol + file:line). The monitor-hotplug crash was found this way.
- Focus bugs: reproduce from the shell and poll `aerospace list-windows --focused` every 100ms around the event.
  `aerospace focus --dfs-index 0` shows which window is first in tree order. `aerospace debug-windows --window-id <id>`
  shows how a window is classified (`Aero.AxUiElementWindowType`: popup/dialog/window).
- App-specific window classification rules go in `isWindowHeuristic` (popup) / `isDialogHeuristic` (float), in
  `Sources/AppBundle/model/AxUiElementWindowType.swift`. Upstream convention is a golden AX-dump test.

## Local changes worth knowing about when they conflict

- `focus-follows-mouse.monitor` (`mouse/focusFollowsMouse.swift`), used with AutoRaise.
- Tabs: headers hidden while `fullscreen`, `gaps.outer.top-tabs`, full-height tab click targets.
- `summon-workspace --when-visible (focus|swap)`.
- Roam button-less windows → popup.
- Fix: `MonitorInfo.toMonitorOrRearrangeMonitors()` falls back to the closest monitor instead of recursing (crash
  on display hotplug); rearrange skipped when `NSScreen.screens` is empty. **Still unfixed upstream**: check
  upstream before dropping.
- Persistent layout (`tree/frozen/persistentLayout.swift` = model/capture/restore, `persistentLayoutStore.swift` =
  file, timer, startup/late-window hooks). Hooks in upstream code: `initAppBundle.swift` (load before the startup
  refresh, restore instead of `smartLayoutAtStartup`, start saving), `refresh.swift` (late windows after `refresh()`),
  `appBundleUtil.swift` (save in `beforeTermination`). Windows are keyed by **native** window id
  (`macApp.nativeWindowId(of:)`); `OpaqueWindowId` is a per-process counter and useless across restarts. Same boot
  (`kern.bootsessionuuid`) → match by native id; after reboot → app bundle id + exact title, only within 90s of startup.
  Saving pauses while locked, during a pending restore, and after `willPowerOff`. A leftover `layout.restoring`
  marker means the last restore crashed and the next start skips restoring. To reset: delete `layout.json`.
- Fix: `Workspace.toLiveFocus()` walks MRU children for one that has a window (focus jumped to the first tab after
  a fullscreen/floating window such as a Flameshot overlay closed). **Still unfixed upstream.**
