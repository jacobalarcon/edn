import Foundation
import Testing
@testable import EDNCore

@Suite("Workspace authoring")
struct WorkspaceAuthoringTests {
    @Test("Create from visible windows produces inspectable effective layout")
    func createAndInspectVisibleWorkspace() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let visibleFrame = Frame(x: 10, y: 20, w: 1000, h: 700)
        let discovery = FakeDiscovery(applications: [
            LiveApplication(
                name: "Browser",
                bundleId: "app.browser",
                processId: 42,
                windows: [LiveWindow(title: "Browser", frame: visibleFrame, displayId: 1)]
            )
        ])
        let author = fixture.author(discovery: discovery)

        let workspace = try author.create(name: "web", hotkey: "1", fromVisibleApplications: true)
        let inspection = try author.inspect(name: "web")

        #expect(workspace.number == 1)
        #expect(workspace.apps == [AppConfig(bundleId: "app.browser", frame: visibleFrame)])
        #expect(inspection.apps[0].configuredFrames == [visibleFrame])
        #expect(inspection.apps[0].rememberedFrames.isEmpty)
        #expect(inspection.apps[0].effectiveFrames == [visibleFrame])
    }

    @Test("Remembered frames override config until reset")
    func resetRestoresConfigAuthority() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let author = fixture.author()
        _ = try author.create(name: "work")
        try fixture.configStore.update { config in
            config.workspaces[0].apps = [
                AppConfig(bundleId: "app.editor", frame: Frame(x: 0, y: 0, w: 800, h: 600))
            ]
        }
        try fixture.stateStore.update { state in
            state.setFrame(Frame(x: 50, y: 60, w: 900, h: 700), workspace: "work", key: "app.editor")
        }

        #expect(try author.inspect(name: "work").apps[0].effectiveFrames == [Frame(x: 50, y: 60, w: 900, h: 700)])
        try author.reset(name: "work")
        let reset = try author.inspect(name: "work").apps[0]
        #expect(reset.rememberedFrames.isEmpty)
        #expect(reset.effectiveFrames == [Frame(x: 0, y: 0, w: 800, h: 600)])
    }

    @Test("Delete removes config, remembered frames, and active workspace")
    func deleteCleansConfigAndState() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let author = fixture.author()
        _ = try author.create(name: "temporary")
        try fixture.stateStore.update { state in
            state.activeWorkspace = "temporary"
            state.setFrame(Frame(x: 1, y: 2, w: 3, h: 4), workspace: "temporary", key: "app")
        }

        try author.delete(name: "temporary")

        #expect(try fixture.configStore.read().workspaces.isEmpty)
        let state = try fixture.stateStore.read()
        #expect(state.activeWorkspace == nil)
        #expect(state.frames["temporary"] == nil)
    }

    @Test("Same-title windows are captured together without identity guessing")
    func sameTitleWindowsBecomeAFrameSet() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let discovery = FakeDiscovery(applications: [
            LiveApplication(name: "Editor", bundleId: "app.editor", processId: 9, windows: [
                LiveWindow(title: "same", frame: Frame(x: 0, y: 0, w: 100, h: 100), displayId: 1),
                LiveWindow(title: "same", frame: Frame(x: 100, y: 0, w: 100, h: 100), displayId: 1)
            ])
        ])

        let workspace = try fixture.author(discovery: discovery)
            .create(name: "multi", fromVisibleApplications: true)

        #expect(workspace.apps == [
            AppConfig(bundleId: "app.editor", frames: [
                Frame(x: 0, y: 0, w: 100, h: 100),
                Frame(x: 100, y: 0, w: 100, h: 100)
            ])
        ])
        #expect(workspace.apps[0].windowTitle == nil)
    }

    @Test("Menu capture saves only the applications the user reviewed")
    func reviewedApplicationsAreExplicit() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let browser = LiveApplication(
            name: "Browser",
            bundleId: "app.browser",
            processId: 42,
            windows: [
                LiveWindow(
                    title: "Browser",
                    frame: Frame(x: 10, y: 20, w: 1000, h: 700),
                    displayId: 1
                )
            ]
        )

        let workspace = try fixture.author().create(
            name: "writing",
            hotkey: "3",
            applications: [browser]
        )

        #expect(workspace.apps.map(\.bundleId) == ["app.browser"])
        #expect(try fixture.configStore.read().workspaces == [workspace])
    }

    @Test("Menu capture refuses an empty application selection")
    func reviewedApplicationsCannotBeEmpty() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }

        do {
            _ = try fixture.author().create(name: "empty", applications: [])
            Issue.record("Expected an empty selection to fail")
        } catch WorkspaceAuthoringError.noVisibleApplications {}

        #expect(try fixture.configStore.read().workspaces.isEmpty)
    }

    @Test("Editing preserves retained layouts and adds installed apps without guessing a layout")
    func editPreservesAndAddsExplicitMembership() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let retainedDefault = Frame(x: 0, y: 0, w: 800, h: 600)
        let retainedMemory = Frame(x: 20, y: 30, w: 900, h: 700)
        _ = try fixture.author().create(name: "work")
        try fixture.configStore.update { config in
            config.workspaces[0].apps = [AppConfig(bundleId: "app.editor", frame: retainedDefault)]
        }
        try fixture.stateStore.update { state in
            state.activeWorkspace = "work"
            state.setWindowFrames([retainedMemory], workspace: "work", key: "app.editor")
        }
        let available = InstalledApplication(
            name: "Browser",
            bundleId: "app.browser"
        )

        let updated = try fixture.author().update(
            name: "work",
            newName: "deep-work",
            hotkey: "4",
            selectedBundleIds: ["app.editor", "app.browser"],
            availableApplications: [available]
        )

        #expect(updated.apps == [
            AppConfig(bundleId: "app.editor", frame: retainedDefault),
            AppConfig(bundleId: "app.browser")
        ])
        let state = try fixture.stateStore.read()
        #expect(state.activeWorkspace == "deep-work")
        #expect(state.windowFrames(workspace: "deep-work", key: "app.editor") == [retainedMemory])
        #expect(state.frames["work"] == nil)
    }

    @Test("Editing removes state only for deliberately unchecked apps")
    func editRemovesUncheckedAppState() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        _ = try fixture.author().create(name: "work")
        try fixture.configStore.update { config in
            config.workspaces[0].apps = [
                AppConfig(bundleId: "app.editor"),
                AppConfig(bundleId: "app.chat")
            ]
        }
        try fixture.stateStore.update { state in
            state.setWindowFrames([Frame(x: 0, y: 0, w: 800, h: 600)], workspace: "work", key: "app.editor")
            state.setWindowFrames([Frame(x: 800, y: 0, w: 800, h: 600)], workspace: "work", key: "app.chat")
        }

        _ = try fixture.author().update(
            name: "work",
            newName: "work",
            hotkey: nil,
            selectedBundleIds: ["app.editor"],
            availableApplications: []
        )

        let state = try fixture.stateStore.read()
        #expect(state.windowFrames(workspace: "work", key: "app.editor") != nil)
        #expect(state.windowFrames(workspace: "work", key: "app.chat") == nil)
        #expect(try fixture.configStore.read().workspaces[0].apps.map(\.bundleId) == ["app.editor"])
    }

    @Test("Editing can leave a workspace empty and clears removed app state")
    func editAllowsEmptyMembership() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        _ = try fixture.author().create(name: "work")
        try fixture.configStore.update { config in
            config.workspaces[0].apps = [
                AppConfig(bundleId: "app.editor"),
                AppConfig(bundleId: "app.browser")
            ]
        }
        try fixture.stateStore.update { state in
            state.activeWorkspace = "work"
            state.setWindowFrames([Frame(x: 0, y: 0, w: 800, h: 600)], workspace: "work", key: "app.editor")
            state.setWindowFrames([Frame(x: 800, y: 0, w: 800, h: 600)], workspace: "work", key: "app.browser")
        }

        let updated = try fixture.author().update(
            name: "work",
            newName: "empty",
            hotkey: "2",
            selectedBundleIds: [],
            availableApplications: []
        )

        #expect(updated == WorkspaceConfig(name: "empty", number: 1, hotkey: "2", apps: []))
        let state = try fixture.stateStore.read()
        #expect(state.activeWorkspace == "empty")
        #expect(state.windowFrames(workspace: "empty", key: "app.editor") == nil)
        #expect(state.windowFrames(workspace: "empty", key: "app.browser") == nil)
        #expect(state.frames["work"] == nil)
    }

    @Test("Blank workspace creation names itself and takes the next free number")
    func createBlankPicksAFreeNameAndNumber() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let author = fixture.author()

        let first = try author.createBlank()
        let second = try author.createBlank()

        #expect(first == WorkspaceConfig(name: "Untitled Workspace", number: 1, hotkey: nil, apps: []))
        #expect(second == WorkspaceConfig(name: "Untitled Workspace 2", number: 2, hotkey: nil, apps: []))
        #expect(try fixture.configStore.read().workspaces == [first, second])
    }

    @Test("Blank workspace creation skips names already taken, case-insensitively")
    func createBlankSkipsTakenNames() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        try fixture.configStore.update { config in
            config.workspaces = [
                WorkspaceConfig(name: "untitled workspace", number: 1),
                WorkspaceConfig(name: "UNTITLED WORKSPACE 2", number: 3)
            ]
        }

        let created = try fixture.author().createBlank()

        #expect(created.name == "Untitled Workspace 3")
        // Appends after the last position (1, 3 -> 1, 2, 3) rather than filling the gap
        // at 2 -- there is no such thing as an unused number to fill anymore.
        #expect(created.number == 3)
    }

    @Test("Available name generation leaves an unused base name alone")
    func availableNameUsesBaseWhenFree() {
        #expect(WorkspaceNaming.availableName(existing: ["work", "play"]) == "Untitled Workspace")
        #expect(WorkspaceNaming.availableName(base: "Writing", existing: ["writing"]) == "Writing 2")
    }

    @Test("Deleting a workspace shifts the remaining positions down, hotkeys untouched")
    func deleteShiftsRemainingPositionsDown() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        try fixture.configStore.update { config in
            config.workspaces = [
                WorkspaceConfig(name: "browser", number: 1, hotkey: "1"),
                WorkspaceConfig(name: "coding", number: 2, hotkey: "2"),
                WorkspaceConfig(name: "browser-term", number: 3, hotkey: "5")
            ]
        }

        try fixture.author().delete(name: "coding")

        let remaining = try fixture.configStore.read().workspaces
        #expect(remaining.map(\.name) == ["browser", "browser-term"])
        #expect(remaining.map(\.number) == [1, 2])
        // Position is not the shortcut: browser-term keeps opt+5 even though it moved
        // from row position 3 to position 2.
        #expect(remaining.first { $0.name == "browser-term" }?.hotkey == "5")
    }

    @Test("A config with gaps or shortcut-matched numbers self-heals to contiguous positions on the next write")
    func legacyGappedNumbersSelfHealOnWrite() throws {
        // Reproduces a legacy config with workspaces numbered to match their hotkeys
        // (1, 2, 5) from before position and shortcut were separated, rather than
        // reflecting row order.
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        try fixture.configStore.update { config in
            config.workspaces = [
                WorkspaceConfig(name: "browser", number: 1, hotkey: "1"),
                WorkspaceConfig(name: "coding", number: 2, hotkey: "2"),
                WorkspaceConfig(name: "browser-term", number: 5, hotkey: "5")
            ]
        }

        // Any write self-heals the numbering -- this uses a metadata edit that touches
        // an unrelated workspace, not the drifted ones, to prove it isn't a targeted fix.
        _ = try fixture.author().updateMetadata(name: "browser", newName: "browser", hotkey: "1")

        let healed = try fixture.configStore.read().workspaces
        #expect(healed.map(\.name) == ["browser", "coding", "browser-term"])
        #expect(healed.map(\.number) == [1, 2, 3])
        #expect(healed.map(\.hotkey) == ["1", "2", "5"])
    }

    @Test("Metadata edits preserve app membership added by another process")
    func metadataEditPreservesExternalMembership() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        try fixture.configStore.update { config in
            config.workspaces = [WorkspaceConfig(
                name: "work",
                number: 1,
                apps: [AppConfig(bundleId: "app.editor")]
            )]
        }
        // This represents an agent edit made after the manager loaded its view model.
        try fixture.configStore.update { config in
            config.workspaces[0].apps.append(AppConfig(bundleId: "app.chat"))
        }

        let updated = try fixture.author().updateMetadata(
            name: "work",
            newName: "focus",
            hotkey: "2"
        )

        #expect(updated.apps.map(\.bundleId) == ["app.editor", "app.chat"])
    }

    @Test("Adding apps unions with the latest membership on disk")
    func addingAppsPreservesExternalMembership() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        try fixture.configStore.update { config in
            config.workspaces = [WorkspaceConfig(
                name: "work",
                number: 1,
                apps: [AppConfig(bundleId: "app.agent-added")]
            )]
        }

        let updated = try fixture.author().addApplications(
            workspace: "work",
            bundleIds: ["app.browser"],
            availableApplications: [InstalledApplication(name: "Browser", bundleId: "app.browser")]
        )

        #expect(updated.apps.map(\.bundleId) == ["app.agent-added", "app.browser"])
    }

    @Test("Removing apps deletes only the selected identities")
    func removingAppsPreservesUnrelatedMembership() throws {
        let fixture = try AuthoringFixture()
        defer { fixture.remove() }
        let scoped = AppConfig(bundleId: "app.editor", windowTitle: "notes")
        try fixture.configStore.update { config in
            config.workspaces = [WorkspaceConfig(
                name: "work",
                number: 1,
                apps: [AppConfig(bundleId: "app.editor"), scoped, AppConfig(bundleId: "app.chat")]
            )]
        }

        let updated = try fixture.author().removeApplications(
            workspace: "work",
            stateKeys: [scoped.stateKey]
        )

        #expect(updated.apps.map(\.stateKey) == ["app.editor", "app.chat"])
    }
}

private struct FakeDiscovery: WorkspaceDiscovering {
    var applications: [LiveApplication] = []

    func visibleDesktop() throws -> LiveDesktopSnapshot {
        LiveDesktopSnapshot(displays: [], applications: applications)
    }
}

private struct AuthoringFixture {
    let root: URL
    let configStore: ConfigStore
    let stateStore: WorkspaceStateStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-authoring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configStore = ConfigStore(url: root.appendingPathComponent("config.json"))
        stateStore = WorkspaceStateStore(url: root.appendingPathComponent("state.json"))
        try Config().save(to: configStore.url)
    }

    func author(discovery: any WorkspaceDiscovering = FakeDiscovery()) -> WorkspaceAuthor {
        WorkspaceAuthor(configStore: configStore, stateStore: stateStore, discovery: discovery)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
