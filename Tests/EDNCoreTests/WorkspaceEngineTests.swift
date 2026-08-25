import Foundation
import ApplicationServices
import Testing
@testable import EDNCore

@Suite("Workspace engine reliability")
struct WorkspaceEngineTests {
    @Test("A presentable target becomes active before the old workspace is hidden")
    func successfulSwitchCommitsActiveWorkspace() throws {
        let fixture = try EngineFixture(activeWorkspace: "old")
        defer { fixture.remove() }
        let windows = FakeWindowManager(activations: ["app.target": .activated])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let results = try engine.switchTo("target")

        #expect(results.count == 1)
        #expect(results[0].appWasPresented)
        #expect(try fixture.store.read().activeWorkspace == "target")
        #expect(windows.hiddenBundleIDs == ["app.old"])
    }

    @Test("A completely unavailable target preserves the active workspace and hides nothing")
    func failedSwitchDoesNotCommitOrHide() throws {
        let fixture = try EngineFixture(activeWorkspace: "old")
        defer { fixture.remove() }
        let windows = FakeWindowManager(activations: ["app.target": .applicationNotFound])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        do {
            _ = try engine.switchTo("target")
            Issue.record("Expected activation failure")
        } catch EngineError.workspaceActivationFailed("target") {}

        #expect(try fixture.store.read().activeWorkspace == "old")
        #expect(windows.hiddenBundleIDs.isEmpty)
    }

    @Test("A manually launched active-workspace app gets only its active layout restored")
    func launchedActiveMemberRestoresLayout() throws {
        let fixture = try EngineFixture(activeWorkspace: "target")
        defer { fixture.remove() }
        let desired = Frame(x: 40, y: 50, w: 900, h: 700)
        var state = try fixture.store.read()
        state.setWindowFrames([desired], workspace: "target", key: "app.target")
        try state.save(to: fixture.store.url)
        let window = FakeManagedWindow(frame: Frame(x: 0, y: 0, w: 400, h: 300))
        let windows = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.target": [window]]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let results = try engine.restoreLaunchedApplication(bundleID: "app.target")

        #expect(results.count == 1)
        #expect(window.appliedFrames == [desired])
        #expect(windows.hiddenBundleIDs.isEmpty)
        #expect(try fixture.store.read().activeWorkspace == "target")
    }

    @Test("A launched app outside the active workspace is left alone")
    func launchedInactiveMemberIsIgnored() throws {
        let fixture = try EngineFixture(activeWorkspace: "target")
        defer { fixture.remove() }
        let windows = FakeWindowManager(activations: ["app.old": .activated])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let results = try engine.restoreLaunchedApplication(bundleID: "app.old")

        #expect(results.isEmpty)
        #expect(windows.activationBundleIDs.isEmpty)
        #expect(windows.hiddenBundleIDs.isEmpty)
    }

    @Test("Saving an unknown workspace is an error")
    func unknownSnapshotFails() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: FakeWindowManager()
        )

        do {
            _ = try engine.snapshot(workspace: "missing")
            Issue.record("Expected workspace lookup failure")
        } catch EngineError.workspaceNotFound("missing") {}
    }

    @Test("A rapid switch preserves the last known layout instead of snapshotting transition geometry")
    func rapidSwitchSkipsOutgoingSnapshot() throws {
        let fixture = try EngineFixture(
            activeWorkspace: "old",
            activeWorkspaceSince: Date()
        )
        defer { fixture.remove() }
        let windows = FakeWindowManager(activations: ["app.target": .activated])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        _ = try engine.switchTo("target")

        #expect(!windows.queriedBundleIDs.contains("app.old"))
    }

    @Test("A settled workspace is snapshotted normally on the way out")
    func settledWorkspaceSnapshotsOutgoingLayout() throws {
        let fixture = try EngineFixture(
            activeWorkspace: "old",
            activeWorkspaceSince: Date().addingTimeInterval(-1)
        )
        defer { fixture.remove() }
        let windows = FakeWindowManager(activations: ["app.target": .activated])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        _ = try engine.switchTo("target")

        #expect(windows.queriedBundleIDs.contains("app.old"))
    }

    @Test("Snapshot captures every standard window as one app-level set")
    func snapshotCapturesWholeWindowSet() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let left = FakeManagedWindow(frame: Frame(x: 0, y: 0, w: 600, h: 800))
        let right = FakeManagedWindow(frame: Frame(x: 600, y: 0, w: 600, h: 800))
        let windows = FakeWindowManager(windows: ["app.target": [right, left]])
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        _ = try engine.snapshot(workspace: "target")

        let state = try fixture.store.read()
        #expect(state.windowFrames(workspace: "target", key: "app.target") == [
            Frame(x: 0, y: 0, w: 600, h: 800),
            Frame(x: 600, y: 0, w: 600, h: 800)
        ])
        #expect(state.activeWorkspace == "target")
        #expect(state.activeWorkspaceSince != nil)
    }

    @Test("Replay applies the complete saved frame set without title matching")
    func replayAppliesWholeWindowSet() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let left = FakeManagedWindow(frame: Frame(x: 20, y: 20, w: 500, h: 500))
        let right = FakeManagedWindow(frame: Frame(x: 700, y: 20, w: 500, h: 500))
        let desired = [
            Frame(x: 0, y: 0, w: 640, h: 900),
            Frame(x: 640, y: 0, w: 640, h: 900)
        ]
        try fixture.store.update { state in
            state.setWindowFrames(desired, workspace: "target", key: "app.target")
        }
        let windows = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.target": [right, left]]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let result = try engine.switchTo("target")

        #expect(result[0].applies.count == 2)
        #expect(left.appliedFrames == [desired[0]])
        #expect(right.appliedFrames == [desired[1]])
    }

    @Test("Replay materializes window attributes once before filtering and sorting")
    func replayMaterializesWindowAttributesOnce() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let left = FakeManagedWindow(title: "left", frame: Frame(x: 20, y: 20, w: 500, h: 500))
        let right = FakeManagedWindow(title: "right", frame: Frame(x: 700, y: 20, w: 500, h: 500))
        let desired = [
            Frame(x: 0, y: 0, w: 640, h: 900),
            Frame(x: 640, y: 0, w: 640, h: 900)
        ]
        try fixture.store.update { state in
            state.setWindowFrames(desired, workspace: "target", key: "app.target")
        }
        let windows = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.target": [right, left]]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        _ = try engine.switchTo("target")

        #expect(left.titleAccessCount == 1)
        #expect(left.subroleAccessCount == 1)
        #expect(left.frameAccessCount == 1)
        #expect(left.isMinimizedAccessCount == 1)
        #expect(right.titleAccessCount == 1)
        #expect(right.subroleAccessCount == 1)
        #expect(right.frameAccessCount == 1)
        #expect(right.isMinimizedAccessCount == 1)
    }

    @Test("Replay restores minimized windows that complete the saved set")
    func replayRestoresMinimizedWindows() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let desired = [
            Frame(x: 0, y: 0, w: 640, h: 900),
            Frame(x: 640, y: 0, w: 640, h: 900)
        ]
        try fixture.store.update { state in
            state.setWindowFrames(desired, workspace: "target", key: "app.target")
        }
        let visible = FakeManagedWindow(frame: Frame(x: 20, y: 20, w: 500, h: 500))
        let minimized = FakeManagedWindow(
            frame: Frame(x: 700, y: 20, w: 500, h: 500),
            isMinimized: true
        )
        let windows = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.target": [minimized, visible]]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let results = try engine.switchTo("target")

        #expect(results[0].issue == nil)
        #expect(minimized.minimizedWrites == [false])
        #expect(visible.appliedFrames == [desired[0]])
        #expect(minimized.appliedFrames == [desired[1]])
    }

    @Test("Replay skips frame writes when geometry already matches")
    func replaySkipsMatchingFrameWrites() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let desired = Frame(x: 20, y: 20, w: 500, h: 500)
        try fixture.store.update { state in
            state.setWindowFrames([desired], workspace: "target", key: "app.target")
        }
        let window = FakeManagedWindow(frame: desired)
        let windows = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.target": [window]]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: windows
        )

        let results = try engine.switchTo("target")

        #expect(window.appliedFrames.isEmpty)
        #expect(results[0].applies.count == 1)
        #expect(results[0].applies[0].fullyMatched)
    }

    @Test("Automatic snapshots replace a saved window set when its count changes")
    func automaticSnapshotReplacesWindowSetOnCountChange() throws {
        // Whatever is on screen when a workspace is left -- window count included --
        // becomes the new remembered truth with no confirmation required. Capturing the
        // current desktop is never ambiguous, so there is nothing to refuse here.
        let fixture = try EngineFixture(
            activeWorkspace: "old",
            activeWorkspaceSince: Date().addingTimeInterval(-1)
        )
        defer { fixture.remove() }
        let remembered = [
            Frame(x: 0, y: 0, w: 500, h: 500),
            Frame(x: 500, y: 0, w: 500, h: 500)
        ]
        try fixture.store.update { state in
            state.setWindowFrames(remembered, workspace: "old", key: "app.old")
        }
        let replacement = Frame(x: 10, y: 10, w: 900, h: 700)
        let manager = FakeWindowManager(
            activations: ["app.target": .activated],
            windows: ["app.old": [FakeManagedWindow(frame: replacement)]]
        )
        let engine = WorkspaceEngine(config: fixture.config, stateStore: fixture.store, windowManager: manager)

        _ = try engine.switchTo("target")

        #expect(try fixture.store.read().windowFrames(workspace: "old", key: "app.old") == [replacement])
    }

    @Test("Explicit save accepts an intentional window-count change")
    func explicitSaveReplacesWindowSetOnCountChange() throws {
        let fixture = try EngineFixture(activeWorkspace: "target")
        defer { fixture.remove() }
        try fixture.store.update { state in
            state.setWindowFrames([
                Frame(x: 0, y: 0, w: 500, h: 500),
                Frame(x: 500, y: 0, w: 500, h: 500)
            ], workspace: "target", key: "app.target")
        }
        let replacement = Frame(x: 50, y: 50, w: 900, h: 700)
        let manager = FakeWindowManager(windows: ["app.target": [FakeManagedWindow(frame: replacement)]])
        let engine = WorkspaceEngine(config: fixture.config, stateStore: fixture.store, windowManager: manager)

        _ = try engine.snapshot(workspace: "target")

        #expect(try fixture.store.read().windowFrames(workspace: "target", key: "app.target") == [replacement])
    }

    @Test("Termination save captures first-ever frames for the active workspace")
    func terminationSaveCapturesFirstEverFrames() throws {
        let fixture = try EngineFixture(activeWorkspace: "target")
        defer { fixture.remove() }
        let frame = Frame(x: 50, y: 60, w: 900, h: 700)
        let manager = FakeWindowManager(windows: ["app.target": [FakeManagedWindow(frame: frame)]])
        let engine = WorkspaceEngine(config: fixture.config, stateStore: fixture.store, windowManager: manager)

        let result = try engine.snapshotActiveWorkspaceForTermination()

        #expect(result?.captured == ["app.target"])
        #expect(try fixture.store.read().windowFrames(workspace: "target", key: "app.target") == [frame])
    }

    @Test("Termination save replaces a remembered window set when count changes")
    func terminationSaveReplacesWindowSetOnCountChange() throws {
        // Quitting is just another way of leaving a workspace -- it gets the same
        // no-confirmation-required capture as an ordinary switch-away.
        let fixture = try EngineFixture(activeWorkspace: "target")
        defer { fixture.remove() }
        let remembered = [
            Frame(x: 0, y: 0, w: 500, h: 500),
            Frame(x: 500, y: 0, w: 500, h: 500)
        ]
        try fixture.store.update { state in
            state.setWindowFrames(remembered, workspace: "target", key: "app.target")
        }
        let replacement = Frame(x: 50, y: 50, w: 900, h: 700)
        let manager = FakeWindowManager(windows: ["app.target": [FakeManagedWindow(frame: replacement)]])
        let engine = WorkspaceEngine(config: fixture.config, stateStore: fixture.store, windowManager: manager)

        let result = try engine.snapshotActiveWorkspaceForTermination()

        #expect(result?.captured == ["app.target"])
        #expect(try fixture.store.read().windowFrames(workspace: "target", key: "app.target") == [replacement])
    }

    @Test("Termination save is a no-op when no workspace is active")
    func terminationSaveNoOpsWithoutActiveWorkspace() throws {
        let fixture = try EngineFixture(activeWorkspace: nil)
        defer { fixture.remove() }
        let manager = FakeWindowManager(windows: ["app.target": [FakeManagedWindow(frame: Frame(x: 1, y: 2, w: 3, h: 4))]])
        let engine = WorkspaceEngine(config: fixture.config, stateStore: fixture.store, windowManager: manager)

        let result = try engine.snapshotActiveWorkspaceForTermination()

        #expect(result == nil)
        #expect(manager.queriedBundleIDs.isEmpty)
    }

    @Test("Representative switch keeps hot path operation counts bounded")
    func representativeSwitchOperationBudget() throws {
        let fixture = try RepresentativeEngineFixture()
        defer { fixture.remove() }
        let oldA = FakeManagedWindow(title: "old-a", frame: Frame(x: 0, y: 0, w: 400, h: 400))
        let oldB = FakeManagedWindow(title: "old-b", frame: Frame(x: 410, y: 0, w: 400, h: 400))
        let newA = FakeManagedWindow(title: "new-a", frame: Frame(x: 0, y: 500, w: 500, h: 500))
        let newB = FakeManagedWindow(title: "new-b", frame: Frame(x: 510, y: 500, w: 500, h: 500))
        let newC = FakeManagedWindow(title: "new-c", frame: Frame(x: 1020, y: 500, w: 500, h: 500))
        let manager = FakeWindowManager(
            activations: [
                "app.new-one": .activated,
                "app.new-two": .activated,
                "app.shared": .activated
            ],
            windows: [
                "app.old-one": [oldA],
                "app.old-two": [oldB],
                "app.new-one": [newA, newB],
                "app.new-two": [newC],
                "app.shared": []
            ]
        )
        let engine = WorkspaceEngine(
            config: fixture.config,
            stateStore: fixture.store,
            windowManager: manager
        )

        _ = try engine.switchTo("new")

        #expect(manager.beginSwitchCount == 1)
        #expect(manager.activationBundleIDs == ["app.new-one", "app.new-two", "app.shared"])
        #expect(manager.waitedBundleIDs == ["app.new-one", "app.new-two"])
        // "app.shared" belongs to both workspaces, so it must be captured first, before
        // the target's frames are applied. The non-shared apps ("app.old-one",
        // "app.old-two") are captured afterward, right before they're hidden.
        #expect(manager.queriedBundleIDs == ["app.shared", "app.old-one", "app.old-two"])
        #expect(Set(manager.hiddenBundleIDs) == ["app.old-one", "app.old-two"])
        #expect(newA.appliedFrames == [Frame(x: 10, y: 10, w: 500, h: 500)])
        #expect(newB.appliedFrames == [Frame(x: 520, y: 10, w: 500, h: 500)])
        #expect(newC.appliedFrames == [Frame(x: 1030, y: 10, w: 500, h: 500)])
        #expect(oldA.frameAccessCount == 1)
        #expect(oldB.frameAccessCount == 1)
        #expect(newA.frameAccessCount == 1)
        #expect(newB.frameAccessCount == 1)
        #expect(newC.frameAccessCount == 1)
    }

    @Test("Non-shared outgoing app's window read happens after the target's frames are applied")
    func nonSharedOutgoingSnapshotDefersUntilAfterTargetPresented() throws {
        // "old" has one app shared with "new" (app.shared) and one app that only lives in
        // "old" (app.old-only). app.shared must be captured before app.new-only's frame is
        // applied (it's read where the snapshot always happened). app.old-only must be
        // captured after app.new-only's frame is applied -- proving the deferred half of
        // the split actually runs after the target is presented, not before.
        let fixture = try EngineFixture(
            activeWorkspace: "old",
            activeWorkspaceSince: Date().addingTimeInterval(-1)
        )
        defer { fixture.remove() }
        let config = Config(workspaces: [
            WorkspaceConfig(name: "old", number: 1, apps: [
                AppConfig(bundleId: "app.shared"),
                AppConfig(bundleId: "app.old-only")
            ]),
            WorkspaceConfig(name: "new", number: 2, apps: [
                AppConfig(bundleId: "app.new-only"),
                AppConfig(bundleId: "app.shared")
            ])
        ])
        try fixture.store.update { state in
            state.setWindowFrames(
                [Frame(x: 0, y: 0, w: 500, h: 500)],
                workspace: "new",
                key: "app.new-only"
            )
        }

        let eventLog = EventLog()
        let newWindow = FakeManagedWindow(title: "new-only", frame: Frame(x: 20, y: 20, w: 500, h: 500), eventLog: eventLog)
        let oldOnlyWindow = FakeManagedWindow(title: "old-only", frame: Frame(x: 0, y: 0, w: 400, h: 400), eventLog: eventLog)
        let manager = FakeWindowManager(
            activations: [
                "app.new-only": .activated,
                "app.shared": .activated
            ],
            windows: [
                "app.new-only": [newWindow],
                "app.old-only": [oldOnlyWindow],
                "app.shared": []
            ],
            eventLog: eventLog
        )
        let engine = WorkspaceEngine(
            config: config,
            stateStore: fixture.store,
            windowManager: manager
        )

        _ = try engine.switchTo("new")

        let events = eventLog.events
        guard let sharedQueryIndex = events.firstIndex(of: "query:app.shared"),
              let applyIndex = events.firstIndex(of: "applyFrame:new-only"),
              let oldOnlyQueryIndex = events.firstIndex(of: "query:app.old-only") else {
            Issue.record("expected events missing from \(events)")
            return
        }

        // Invariant 1: the shared app is captured before the target's frame is applied.
        #expect(sharedQueryIndex < applyIndex)
        // Invariant 2: the non-shared app is captured after the target's frame is applied.
        #expect(applyIndex < oldOnlyQueryIndex)
    }
}

/// Records cross-object call order (window queries, frame applies, etc.) so a test can
/// assert one fake's call happened before/after another's, not just that both happened.
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private final class FakeWindowManager: WindowManaging {
    var isTrusted = true
    var activations: [String: AppActivationResult]
    var managedWindows: [String: [any ManagedWindow]]
    private let eventLog: EventLog?
    private(set) var beginSwitchCount = 0
    private(set) var hiddenBundleIDs: [String] = []
    private(set) var activationBundleIDs: [String] = []
    private(set) var queriedBundleIDs: [String] = []
    private(set) var waitedBundleIDs: [String] = []

    init(
        activations: [String: AppActivationResult] = [:],
        windows: [String: [any ManagedWindow]] = [:],
        eventLog: EventLog? = nil
    ) {
        self.activations = activations
        managedWindows = windows
        self.eventLog = eventLog
    }

    func beginSwitch() {
        beginSwitchCount += 1
    }
    func windows(forBundleID bundleID: String) -> [any ManagedWindow] {
        queriedBundleIDs.append(bundleID)
        eventLog?.record("query:\(bundleID)")
        return managedWindows[bundleID] ?? []
    }
    func waitForWindow(bundleID: String, timeout: TimeInterval) -> [any ManagedWindow] {
        waitedBundleIDs.append(bundleID)
        eventLog?.record("wait:\(bundleID)")
        return managedWindows[bundleID] ?? []
    }
    func hide(bundleID: String) -> AppHideResult {
        hiddenBundleIDs.append(bundleID)
        eventLog?.record("hide:\(bundleID)")
        return .hidden
    }
    func activate(bundleID: String, timeout: TimeInterval) -> AppActivationResult {
        activationBundleIDs.append(bundleID)
        eventLog?.record("activate:\(bundleID)")
        return activations[bundleID] ?? .applicationNotFound
    }
}

private final class FakeManagedWindow: ManagedWindow {
    private let storedTitle: String
    private let storedSubrole: String
    private var storedFrame: Frame?
    private var storedIsMinimized: Bool
    private let eventLog: EventLog?
    private(set) var titleAccessCount = 0
    private(set) var subroleAccessCount = 0
    private(set) var frameAccessCount = 0
    private(set) var isMinimizedAccessCount = 0
    private(set) var appliedFrames: [Frame] = []
    private(set) var minimizedWrites: [Bool] = []

    var title: String {
        titleAccessCount += 1
        return storedTitle
    }
    var subrole: String {
        subroleAccessCount += 1
        return storedSubrole
    }
    var frame: Frame? {
        frameAccessCount += 1
        return storedFrame
    }
    var isMinimized: Bool {
        isMinimizedAccessCount += 1
        return storedIsMinimized
    }

    init(
        title: String = "window",
        frame: Frame?,
        isMinimized: Bool = false,
        subrole: String = kAXStandardWindowSubrole as String,
        eventLog: EventLog? = nil
    ) {
        storedTitle = title
        storedFrame = frame
        storedIsMinimized = isMinimized
        storedSubrole = subrole
        self.eventLog = eventLog
    }

    func setFrame(_ frame: Frame) -> FrameApplyResult {
        appliedFrames.append(frame)
        storedFrame = frame
        eventLog?.record("applyFrame:\(storedTitle)")
        return FrameApplyResult(requested: frame, actual: frame)
    }

    func setMinimized(_ minimized: Bool) -> Bool {
        minimizedWrites.append(minimized)
        storedIsMinimized = minimized
        return true
    }
}

private struct EngineFixture {
    let root: URL
    let store: WorkspaceStateStore
    let config: Config

    init(activeWorkspace: String?, activeWorkspaceSince: Date? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WorkspaceStateStore(url: root.appendingPathComponent("state.json"))
        try WorkspaceState(
            activeWorkspace: activeWorkspace,
            activeWorkspaceSince: activeWorkspaceSince
        ).save(to: store.url)
        config = Config(workspaces: [
            WorkspaceConfig(name: "old", number: 1, apps: [AppConfig(bundleId: "app.old")]),
            WorkspaceConfig(name: "target", number: 2, apps: [AppConfig(bundleId: "app.target")])
        ])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RepresentativeEngineFixture {
    let root: URL
    let store: WorkspaceStateStore
    let config: Config

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WorkspaceStateStore(url: root.appendingPathComponent("state.json"))
        var state = WorkspaceState(
            activeWorkspace: "old",
            activeWorkspaceSince: Date().addingTimeInterval(-1)
        )
        state.setWindowFrames([Frame(x: 10, y: 10, w: 500, h: 500), Frame(x: 520, y: 10, w: 500, h: 500)], workspace: "new", key: "app.new-one")
        state.setWindowFrames([Frame(x: 1030, y: 10, w: 500, h: 500)], workspace: "new", key: "app.new-two")
        try state.save(to: store.url)
        config = Config(workspaces: [
            WorkspaceConfig(name: "old", number: 1, apps: [
                AppConfig(bundleId: "app.old-one"),
                AppConfig(bundleId: "app.old-two"),
                AppConfig(bundleId: "app.shared")
            ]),
            WorkspaceConfig(name: "new", number: 2, apps: [
                AppConfig(bundleId: "app.new-one"),
                AppConfig(bundleId: "app.new-two"),
                AppConfig(bundleId: "app.shared")
            ])
        ])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
