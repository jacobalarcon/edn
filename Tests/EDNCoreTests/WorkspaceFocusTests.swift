import Foundation
import ApplicationServices
import Testing
@testable import EDNCore

@Suite("Workspace focus")
struct WorkspaceFocusTests {
    @Test("Cycles running apps in explicit workspace order and wraps")
    func cyclesAndWraps() throws {
        let fixture = try FocusFixture(frontmost: "app.browser", running: ["app.browser", "app.term"])
        let next = try fixture.controller.focus(.next)
        #expect(next.bundleId == "app.term")
        #expect(fixture.applications.focused == ["app.term"])

        fixture.applications.frontmostBundleId = "app.term"
        let wrapped = try fixture.controller.focus(.next)
        #expect(wrapped.bundleId == "app.browser")
    }

    @Test("Previous starts from the last running member when focus is outside EDN")
    func previousFromOutside() throws {
        let fixture = try FocusFixture(frontmost: "app.notes", running: ["app.browser", "app.term", "app.notes"])
        let result = try fixture.controller.focus(.previous)
        #expect(result.bundleId == "app.term")
    }

    @Test("Skips stopped members, deduplicates bundle ids, and never launches")
    func filtersCandidates() throws {
        let fixture = try FocusFixture(frontmost: "app.browser", running: ["app.browser"])
        let result = try fixture.controller.focus(.next)
        #expect(result.bundleId == "app.browser")
        #expect(fixture.applications.focused == ["app.browser"])
    }

    @Test("Refuses honestly when no workspace or member app is available")
    func errors() throws {
        let fixture = try FocusFixture(frontmost: nil, running: [])
        #expect(throws: WorkspaceFocusError.noRunningApplications("work")) {
            try fixture.controller.focus(.next)
        }

        try fixture.stateStore.update { $0.activeWorkspace = nil }
        #expect(throws: WorkspaceFocusError.noActiveWorkspace) {
            try fixture.controller.focus(.next)
        }
    }

    @Test("Window focus visits every live window before advancing to the next app")
    func cyclesWindowsAcrossApps() throws {
        let browserOne = FakeFocusableWindow(title: "A", isMain: true)
        let browserTwo = FakeFocusableWindow(title: "B")
        let terminal = FakeFocusableWindow(title: "Terminal")
        let fixture = try FocusFixture(
            frontmost: "app.browser",
            running: ["app.browser", "app.term"],
            windows: [
                "app.browser": [browserOne, browserTwo],
                "app.term": [terminal]
            ]
        )

        let secondBrowser = try fixture.controller.focusWindow(.next)
        #expect(secondBrowser.bundleId == "app.browser")
        #expect(secondBrowser.windowTitle == "B")
        #expect(secondBrowser.target == .window)

        let terminalResult = try fixture.controller.focusWindow(.next)
        #expect(terminalResult.bundleId == "app.term")
        #expect(terminalResult.windowTitle == "Terminal")

        let wrapped = try fixture.controller.focusWindow(.next)
        #expect(wrapped.bundleId == "app.browser")
        #expect(wrapped.windowTitle == "A")
        #expect(fixture.applications.focusedWindows == ["B", "Terminal", "A"])
    }

    @Test("Window focus skips minimized and nonstandard windows")
    func filtersWindows() throws {
        let minimized = FakeFocusableWindow(title: "Minimized", isMinimized: true)
        let dialog = FakeFocusableWindow(title: "Dialog", subrole: "AXDialog")
        let terminal = FakeFocusableWindow(title: "Terminal")
        let fixture = try FocusFixture(
            frontmost: "app.browser",
            running: ["app.browser", "app.term"],
            windows: [
                "app.browser": [minimized, dialog],
                "app.term": [terminal]
            ]
        )

        let result = try fixture.controller.focusWindow(.next)
        #expect(result.bundleId == "app.term")
        #expect(result.windowTitle == "Terminal")
    }
}

private final class FakeApplicationFocuser: ApplicationFocusing {
    var frontmostBundleId: String?
    var runningBundleIds: Set<String>
    var focused: [String] = []
    var focusedWindows: [String] = []
    var windowsByBundleId: [String: [FakeFocusableWindow]]

    init(frontmost: String?, running: Set<String>, windows: [String: [FakeFocusableWindow]]) {
        frontmostBundleId = frontmost
        runningBundleIds = running
        windowsByBundleId = windows
    }

    func focus(bundleId: String) -> Bool {
        focused.append(bundleId)
        frontmostBundleId = bundleId
        return true
    }

    func windows(bundleId: String) -> [any ManagedWindow] {
        windowsByBundleId[bundleId] ?? []
    }

    func focus(window: any ManagedWindow, bundleId: String) -> Bool {
        guard let target = window as? FakeFocusableWindow else { return false }
        for window in windowsByBundleId.values.flatMap({ $0 }) { window.isMain = false }
        target.isMain = true
        frontmostBundleId = bundleId
        focusedWindows.append(target.title)
        return true
    }
}

private final class FakeFocusableWindow: ManagedWindow {
    let title: String
    let subrole: String
    var frame: Frame?
    let isMinimized: Bool
    var isMain: Bool

    init(
        title: String,
        subrole: String = kAXStandardWindowSubrole,
        frame: Frame? = Frame(x: 0, y: 0, w: 100, h: 100),
        isMinimized: Bool = false,
        isMain: Bool = false
    ) {
        self.title = title
        self.subrole = subrole
        self.frame = frame
        self.isMinimized = isMinimized
        self.isMain = isMain
    }

    func setFrame(_ frame: Frame) -> FrameApplyResult {
        self.frame = frame
        return FrameApplyResult(requested: frame, actual: frame)
    }

    func setMinimized(_ minimized: Bool) -> Bool { false }
    func focus() -> Bool { true }
}

private struct FocusFixture {
    let applications: FakeApplicationFocuser
    let stateStore: WorkspaceStateStore
    let controller: WorkspaceFocusController

    init(
        frontmost: String?,
        running: Set<String>,
        windows: [String: [FakeFocusableWindow]] = [:]
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let stateURL = directory.appendingPathComponent("state.json")
        try Config(workspaces: [
            WorkspaceConfig(name: "work", number: 1, apps: [
                AppConfig(bundleId: "app.browser"),
                AppConfig(bundleId: "app.term"),
                AppConfig(bundleId: "app.browser", windowTitle: "profile")
            ])
        ]).save(to: configURL)
        stateStore = WorkspaceStateStore(url: stateURL)
        try stateStore.update { $0.activeWorkspace = "work" }
        applications = FakeApplicationFocuser(frontmost: frontmost, running: running, windows: windows)
        controller = WorkspaceFocusController(
            configURL: configURL,
            stateStore: stateStore,
            applications: applications
        )
    }
}
