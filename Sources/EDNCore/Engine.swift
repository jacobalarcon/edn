import ApplicationServices
import Foundation

public enum EngineError: Error, CustomStringConvertible {
    case notTrusted
    case workspaceNotFound(String)
    case workspaceActivationFailed(String)

    public var description: String {
        switch self {
        case .notTrusted:
            return "Accessibility permission not granted. Grant it in System Settings > Privacy & Security > Accessibility."
        case .workspaceNotFound(let name):
            return "No workspace named '\(name)' in config."
        case .workspaceActivationFailed(let name):
            return "Workspace '\(name)' could not be activated because none of its apps could be presented."
        }
    }
}

public enum SwitchIssue: Equatable {
    case windowCountMismatch(expected: Int, actual: Int)
}

public struct SwitchResult {
    public let bundleId: String
    public let activation: AppActivationResult
    public let applies: [FrameApplyResult]
    public let issue: SwitchIssue?

    init(
        bundleId: String,
        activation: AppActivationResult,
        applies: [FrameApplyResult],
        issue: SwitchIssue? = nil
    ) {
        self.bundleId = bundleId
        self.activation = activation
        self.applies = applies
        self.issue = issue
    }

    public var appWasPresented: Bool {
        activation.succeeded || applies.contains(where: { $0.actual != nil })
    }

    public var summary: String {
        if !activation.succeeded, !applies.contains(where: { $0.actual != nil }) {
            return "\(bundleId): FAILED (\(activation.failureDescription ?? "application unavailable"))"
        }
        guard !applies.isEmpty else { return "\(bundleId): ok (no saved layout)" }
        let matched = applies.filter(\.fullyMatched).count
        if matched == applies.count {
            let windows = applies.count == 1 ? "window" : "windows"
            return "\(bundleId): ok (\(applies.count) \(windows))"
        }
        let missing = applies.filter { $0.actual == nil }.count
        return "\(bundleId): partial (\(matched)/\(applies.count) windows matched, \(missing) missing)"
    }
}

public struct SnapshotResult {
    public let workspace: String
    public let captured: [String]
    public let missing: [String]

    public var fullyCaptured: Bool { missing.isEmpty }
}

private func warn(_ message: String) {
    FileHandle.standardError.write("edn: warning: \(message)\n".data(using: .utf8)!)
}

private struct WindowSnapshot {
    let window: any ManagedWindow
    let title: String
    let subrole: String
    let frame: Frame?
    let isMinimized: Bool

    init(_ window: any ManagedWindow) {
        self.window = window
        title = window.title
        subrole = window.subrole
        frame = window.frame
        isMinimized = window.isMinimized
    }

    func restoreAndSetFrameIfNeeded(_ desired: Frame) -> FrameApplyResult {
        if isMinimized, !window.setMinimized(false) {
            return FrameApplyResult(requested: desired, actual: nil)
        }
        if let frame, frame.matches(desired) {
            return FrameApplyResult(requested: desired, actual: frame)
        }
        return window.setFrame(desired)
    }
}

public final class WorkspaceEngine {
    public private(set) var config: Config
    private let stateStore: WorkspaceStateStore
    private let windowManager: any WindowManaging

    /// Minimum time a workspace must have been active before its on-screen geometry is
    /// trusted as user-authored. Below this, EDN's own window move (still visually
    /// settling) or a mid-transition frame from a rapid switch storm gets captured as if
    /// the user had dragged it there, permanently corrupting the remembered layout. This
    /// single guard also coalesces rapid-fire switches: each one in a burst skips
    /// snapshotting the still-settling previous workspace, so only the last requested
    /// workspace's frames are ever captured on the way out.
    private static let minimumDwellBeforeSnapshot: TimeInterval = 0.35

    /// The workspace active as of the last switch (persisted, survives across CLI invocations).
    public func activeWorkspace() throws -> String? {
        try stateStore.read().activeWorkspace
    }

    public init(
        config: Config,
        stateStore: WorkspaceStateStore = WorkspaceStateStore(),
        windowManager: any WindowManaging = SystemWindowManager()
    ) {
        self.config = config
        self.stateStore = stateStore
        self.windowManager = windowManager
    }

    public func reloadConfig(from url: URL = Config.defaultPath) throws {
        config = try EDNInstrumentation.measure("config.reload") {
            try Config.load(from: url)
        }
    }

    /// Restores only a newly launched app when it belongs to the active workspace.
    /// This is intentionally not a workspace switch: no outgoing snapshot, no hiding,
    /// no active-workspace mutation, and no inference when the app isn't a member.
    @discardableResult
    public func restoreLaunchedApplication(bundleID: String) throws -> [SwitchResult] {
        guard windowManager.isTrusted else { throw EngineError.notTrusted }
        let state = try stateStore.read()
        guard let activeName = state.activeWorkspace,
              let workspace = config.workspaces.first(where: { $0.name == activeName }) else {
            return []
        }
        let matchingApps = workspace.apps.filter { $0.bundleId == bundleID }
        guard !matchingApps.isEmpty else { return [] }

        windowManager.beginSwitch()
        return matchingApps.map { app in
            let desiredFrames = state.windowFrames(workspace: activeName, key: app.stateKey)
                ?? app.configuredFrames
            return presentApp(app, desiredFrames: desiredFrames, workspaceName: activeName)
        }
    }

    /// Snapshots current frames for the given workspace's apps into state.
    @discardableResult
    public func snapshot(workspace name: String) throws -> SnapshotResult {
        guard let workspace = config.workspaces.first(where: { $0.name == name }) else {
            throw EngineError.workspaceNotFound(name)
        }
        return try stateStore.update { state in
            let result = EDNInstrumentation.measure("snapshot.\(workspace.name)") {
                snapshotLoadedState(workspace, state: &state)
            }
            // An explicit save declares that the desktop currently on screen belongs
            // to this workspace. Without this, the next switch can snapshot the same
            // geometry back into whichever workspace happened to be active before save.
            state.activeWorkspace = name
            state.activeWorkspaceSince = Date()
            return result
        }
    }

    /// Saves the currently active workspace on normal app shutdown, same as an
    /// automatic outgoing snapshot: whatever is on screen right now is what gets
    /// remembered, window count included -- quitting is just another way of leaving.
    @discardableResult
    public func snapshotActiveWorkspaceForTermination() throws -> SnapshotResult? {
        guard windowManager.isTrusted else { throw EngineError.notTrusted }
        return try stateStore.update { state in
            guard let active = state.activeWorkspace else { return nil }
            guard let workspace = config.workspaces.first(where: { $0.name == active }) else {
                throw EngineError.workspaceNotFound(active)
            }
            let result = EDNInstrumentation.measure("snapshot.termination.\(workspace.name)") {
                snapshotLoadedState(workspace, state: &state)
            }
            state.activeWorkspaceSince = Date()
            return result
        }
    }

    /// Snapshots into the state transaction already held by the enclosing operation.
    /// Whatever is on screen when a workspace is left -- moved, resized, opened, or
    /// closed -- becomes the new remembered truth, no confirmation required. Capturing
    /// the current desktop is never ambiguous: EDN can see exactly what exists. The
    /// only place ambiguity can arise is later, on replay, if the live window count no
    /// longer matches what was saved -- see switchTo's window-matching below, which is
    /// the one place EDN still refuses rather than guesses.
    private func snapshotLoadedState(
        _ workspace: WorkspaceConfig,
        state: inout WorkspaceState
    ) -> SnapshotResult {
        snapshotLoadedState(workspace, apps: workspace.apps, state: &state)
    }

    /// Snapshots only the given subset of a workspace's apps. Used by `switchTo` to split
    /// the outgoing workspace's capture into a "shared with target" batch (must run before
    /// the target's frames are applied, or a shared app's target-workspace frame would get
    /// written into the outgoing workspace's saved layout) and a "not shared" batch (safe to
    /// defer until just before those apps are hidden, since nothing touches their geometry
    /// in between).
    private func snapshotLoadedState(
        _ workspace: WorkspaceConfig,
        apps: [AppConfig],
        state: inout WorkspaceState
    ) -> SnapshotResult {
        var captured: [String] = []
        var missing: [String] = []
        for app in apps {
            let windows = standardWindows(materialize(windowManager.windows(forBundleID: app.bundleId)))
            traceWindowMatch(
                phase: "snapshot",
                workspace: workspace.name,
                app: app,
                windows: windows,
                desiredFrames: []
            )
            let capturedFrames: [Frame]
            if app.windowTitle != nil {
                capturedFrames = selectWindow(windows, for: app)?.frame.map { [$0] } ?? []
            } else {
                capturedFrames = windows.compactMap(\.frame).sorted(by: Self.frameComesBefore)
            }
            guard !capturedFrames.isEmpty else {
                // Nothing visible for this app right now (not running, or fully hidden)
                // is not evidence the user wants its remembered layout erased.
                missing.append(app.stateKey)
                continue
            }
            state.setWindowFrames(capturedFrames, workspace: workspace.name, key: app.stateKey)
            captured.append(app.stateKey)
        }
        return SnapshotResult(workspace: workspace.name, captured: captured, missing: missing)
    }

    /// Selects the window an AppConfig entry refers to, warning (not silently guessing)
    /// when an explicit windowTitle was configured but nothing currently open matches it.
    private func selectWindow(_ windows: [WindowSnapshot], for app: AppConfig) -> WindowSnapshot? {
        if let needle = app.windowTitle, !needle.isEmpty {
            if let match = windows.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) {
                return match
            }
            warn("no window of \(app.bundleId) matched title \"\(needle)\"; refusing to move a different window. Titles currently open: \(windows.map(\.title))")
            return nil
        }
        return windows.first
    }

    private func materialize(_ windows: [any ManagedWindow]) -> [WindowSnapshot] {
        windows.map(WindowSnapshot.init)
    }

    private func standardWindows(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter {
            $0.subrole == (kAXStandardWindowSubrole as String) && !$0.isMinimized && $0.frame != nil
        }
    }

    private func standardWindowsIncludingMinimized(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter {
            $0.subrole == (kAXStandardWindowSubrole as String) && $0.frame != nil
        }
    }

    private static func frameComesBefore(_ lhs: Frame, _ rhs: Frame) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.w != rhs.w { return lhs.w < rhs.w }
        return lhs.h < rhs.h
    }

    private func traceWindowMatch(
        phase: String,
        workspace: String,
        app: AppConfig,
        windows: [WindowSnapshot],
        desiredFrames: [Frame]
    ) {
        guard EDNInstrumentation.isTracing else { return }
        let candidates = windows.enumerated().map { index, window in
            "#\(index) title=\(String(reflecting: window.title)) frame=\(Self.traceDescription(window.frame))"
        }.joined(separator: "; ")
        let desired = desiredFrames.enumerated().map { index, frame in
            "#\(index) \(Self.traceDescription(frame))"
        }.joined(separator: "; ")
        EDNInstrumentation.trace(
            "window-match phase=\(phase) workspace=\(String(reflecting: workspace)) "
                + "app=\(app.bundleId) title-filter=\(String(reflecting: app.windowTitle)) "
                + "candidates=[\(candidates)] desired=[\(desired)]"
        )
    }

    private static func traceDescription(_ frame: Frame?) -> String {
        guard let frame else { return "nil" }
        return "(x:\(frame.x),y:\(frame.y),w:\(frame.w),h:\(frame.h))"
    }

    /// Switches to the named workspace: reloads shared state, snapshots the outgoing one,
    /// hides apps not in the target workspace, activates the target's apps, and applies frames.
    @discardableResult
    public func switchTo(_ name: String) throws -> [SwitchResult] {
        guard windowManager.isTrusted else { throw EngineError.notTrusted }
        guard let target = config.workspaces.first(where: { $0.name == name }) else {
            throw EngineError.workspaceNotFound(name)
        }
        windowManager.beginSwitch()
        let countersBefore = EDNInstrumentation.snapshot()
        defer { EDNInstrumentation.traceCounterDelta(since: countersBefore, label: "switch.\(name)") }

        return try EDNInstrumentation.measure("switch.\(name)") {
            try stateStore.update { state in
                // Deferred until after the target is presented (see below): the outgoing
                // workspace's apps that don't also belong to the target. Their on-screen
                // geometry can't change before they're hidden, so reading it early would
                // only cost time in front of the target appearing, for no benefit.
                var deferredOutgoingSnapshot: (workspace: WorkspaceConfig, apps: [AppConfig])?

                if let current = state.activeWorkspace,
                   current != name,
                   let outgoing = config.workspaces.first(where: { $0.name == current }) {
                    let dwell = max(0, state.activeWorkspaceSince.map { Date().timeIntervalSince($0) } ?? .infinity)
                    if dwell >= Self.minimumDwellBeforeSnapshot {
                        // Apps present in both the outgoing and target workspaces must be
                        // captured now, before any target frame is applied -- otherwise the
                        // target's frame for a shared app would be read back and written
                        // into the outgoing workspace's saved layout, corrupting it.
                        let targetBundleIds = Set(target.apps.map(\.bundleId))
                        let sharedApps = outgoing.apps.filter { targetBundleIds.contains($0.bundleId) }
                        let nonSharedApps = outgoing.apps.filter { !targetBundleIds.contains($0.bundleId) }
                        _ = EDNInstrumentation.measure("snapshot.outgoing.\(outgoing.name)") {
                            snapshotLoadedState(outgoing, apps: sharedApps, state: &state)
                        }
                        deferredOutgoingSnapshot = (outgoing, nonSharedApps)
                    } else {
                        warn("skipped snapshotting '\(current)' -- active only \(Int(dwell * 1000))ms, too recent to trust its on-screen geometry as user-authored")
                    }
                }

                // Saved state (your actual last-known layout) wins over config, which is
                // only the starting default for a workspace's first-ever switch. Read this
                // up front, outside the concurrent section below, since `state` is `inout`
                // and can't be safely touched from multiple threads at once.
                let desiredFramesByApp: [[Frame]] = target.apps.map { app in
                    state.windowFrames(workspace: name, key: app.stateKey) ?? app.configuredFrames
                }

                // Keep app presentation ordered. Besides making focus deterministic, this
                // avoids concurrent AppKit/AX access and shared-memory races. A future
                // prepare-hidden/reveal pipeline can remove visual stagger without making
                // activation order nondeterministic.
                let finalResults = target.apps.enumerated().map { index, app in
                    presentApp(
                        app,
                        desiredFrames: desiredFramesByApp[index],
                        workspaceName: name
                    )
                }
                guard target.apps.isEmpty || finalResults.contains(where: \.appWasPresented) else {
                    throw EngineError.workspaceActivationFailed(name)
                }

                // Capture the outgoing workspace's non-shared apps now: the target has
                // already been presented, so this no longer sits in front of what the user
                // is waiting to see, but it must still happen before the hide loop below --
                // these apps need to be read while still visible in their pre-switch state.
                if let deferred = deferredOutgoingSnapshot {
                    _ = EDNInstrumentation.measure("snapshot.outgoing.\(deferred.workspace.name)") {
                        snapshotLoadedState(deferred.workspace, apps: deferred.apps, state: &state)
                    }
                }

                // Only hide the old workspace after at least part of the target is actually
                // available. A broken bundle id must not leave the user staring at an empty desktop.
                let targetBundleIds = Set(target.apps.map(\.bundleId))
                let otherBundleIds = config.workspaces
                    .filter { $0.name != name }
                    .flatMap { $0.apps.map(\.bundleId) }
                let bundleIdsToHide = Array(Set(otherBundleIds).subtracting(targetBundleIds)).sorted()
                // Still one call to `hide()` per app, still fully sequential -- just a
                // single shared-deadline poll for whichever ones didn't hide immediately,
                // instead of each paying its own up-to-0.4s wait back-to-back.
                let hideResults = EDNInstrumentation.measure("hide.batch") {
                    windowManager.hide(bundleIDs: bundleIdsToHide)
                }
                for bundleId in bundleIdsToHide {
                    if hideResults[bundleId]?.succeeded != true {
                        warn("\(bundleId) refused to hide while switching to '\(name)'")
                    }
                }

                state.activeWorkspace = name
                state.activeWorkspaceSince = Date()
                return finalResults
            }
        }
    }

    /// Presents one app for a workspace switch: activate/launch, wait for its windows,
    /// apply the saved layout. A separate reposition-before-reveal experiment was tried
    /// and reverted here: it broke the hot-path operation-count guarantees
    /// (WorkspaceEngineTests "materializes window attributes once", "keeps hot path
    /// operation counts bounded") by querying each app's windows twice. Worth revisiting,
    /// but as a change that preserves the single-query contract rather than adding a second.
    private func presentApp(_ app: AppConfig, desiredFrames: [Frame], workspaceName: String) -> SwitchResult {
        guard !desiredFrames.isEmpty else {
            let activation = EDNInstrumentation.measure("activate.\(app.bundleId)") {
                windowManager.activate(bundleID: app.bundleId, timeout: 5)
            }
            return SwitchResult(bundleId: app.bundleId, activation: activation, applies: [])
        }

        let activation = EDNInstrumentation.measure("activate.\(app.bundleId)") {
            windowManager.activate(bundleID: app.bundleId, timeout: 5)
        }
        let availableWindows = EDNInstrumentation.measure("windows.\(app.bundleId)") {
            activation.succeeded
                ? windowManager.waitForWindow(bundleID: app.bundleId, timeout: 5)
                : windowManager.windows(forBundleID: app.bundleId)
        }
        // A minimized saved window is recoverable, not missing. Include it in count
        // matching, then restore only windows participating in the complete saved set.
        let windows = standardWindowsIncludingMinimized(materialize(availableWindows))
        traceWindowMatch(
            phase: "replay",
            workspace: workspaceName,
            app: app,
            windows: windows,
            desiredFrames: desiredFrames
        )
        let targets: [(WindowSnapshot?, Frame)]
        if app.windowTitle != nil {
            targets = [(selectWindow(windows, for: app), desiredFrames[0])]
        } else {
            let orderedWindows = windows.sorted {
                guard let lhs = $0.frame, let rhs = $1.frame else { return $0.title < $1.title }
                return Self.frameComesBefore(lhs, rhs)
            }
            let orderedFrames = desiredFrames.sorted(by: Self.frameComesBefore)
            guard orderedWindows.count == orderedFrames.count else {
                warn("\(app.bundleId) has \(orderedWindows.count) standard windows but workspace '\(workspaceName)' remembers \(orderedFrames.count); refusing to guess which window is which for this switch. Arrange the windows the way you want them, then switch away -- the new arrangement is remembered automatically.")
                let failed = orderedFrames.map { FrameApplyResult(requested: $0, actual: nil) }
                return SwitchResult(
                    bundleId: app.bundleId,
                    activation: activation,
                    applies: failed,
                    issue: .windowCountMismatch(expected: orderedFrames.count, actual: orderedWindows.count)
                )
            }
            targets = zip(orderedWindows, orderedFrames).map { ($0.0, $0.1) }
        }
        let applies = EDNInstrumentation.measure("replay.\(app.bundleId)") {
            targets.map { window, frame in
                window?.restoreAndSetFrameIfNeeded(frame) ?? FrameApplyResult(requested: frame, actual: nil)
            }
        }
        return SwitchResult(bundleId: app.bundleId, activation: activation, applies: applies)
    }
}
