import Foundation

public enum WorkspaceAuthoringError: Error, CustomStringConvertible {
    case workspaceAlreadyExists(String)
    case workspaceNotFound(String)
    case noVisibleApplications
    case applicationUnavailable(String)
    case duplicateApplicationProcess(String)
    case ambiguousWindows(bundleId: String, reason: String)

    public var description: String {
        switch self {
        case .workspaceAlreadyExists(let name):
            return "A workspace named '\(name)' already exists."
        case .workspaceNotFound(let name):
            return "No workspace named '\(name)' exists."
        case .noVisibleApplications:
            return "No visible application windows were found to capture."
        case .applicationUnavailable(let bundleId):
            return "'\(bundleId)' is not already in the workspace and could not be found in the application picker."
        case .duplicateApplicationProcess(let bundleId):
            return "Multiple running processes use bundle id '\(bundleId)'; EDN cannot identify which one to restore."
        case .ambiguousWindows(let bundleId, let reason):
            return "Windows for '\(bundleId)' cannot be identified reliably: \(reason)"
        }
    }
}

public struct InspectedApp: Encodable, Equatable {
    public let bundleId: String
    public let windowTitle: String?
    public let configuredFrames: [Frame]
    public let rememberedFrames: [Frame]
    public let effectiveFrames: [Frame]

    private enum CodingKeys: String, CodingKey {
        case bundleId, windowTitle, configuredFrames, rememberedFrames, effectiveFrames
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleId, forKey: .bundleId)
        if let windowTitle { try container.encode(windowTitle, forKey: .windowTitle) }
        else { try container.encodeNil(forKey: .windowTitle) }
        try container.encode(configuredFrames, forKey: .configuredFrames)
        try container.encode(rememberedFrames, forKey: .rememberedFrames)
        try container.encode(effectiveFrames, forKey: .effectiveFrames)
    }
}

public struct WorkspaceInspection: Encodable, Equatable {
    public let name: String
    public let number: Int
    public let hotkey: String?
    public let isActive: Bool
    public let apps: [InspectedApp]
}

/// Names for workspaces created without one, so a blank workspace can exist the moment
/// it is created and be renamed afterwards. Config names are compared case-insensitively.
public enum WorkspaceNaming {
    public static let untitledBase = "Untitled Workspace"

    public static func availableName(base: String = untitledBase, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}

/// Shared authoring operations used by both the CLI and the future menu-bar app.
public struct WorkspaceAuthor {
    public let configStore: ConfigStore
    public let stateStore: WorkspaceStateStore
    private let discovery: any WorkspaceDiscovering

    public init(
        configStore: ConfigStore = ConfigStore(),
        stateStore: WorkspaceStateStore = WorkspaceStateStore(),
        discovery: any WorkspaceDiscovering = SystemWorkspaceDiscovery()
    ) {
        self.configStore = configStore
        self.stateStore = stateStore
        self.discovery = discovery
    }

    @discardableResult
    public func create(
        name: String,
        hotkey: String? = nil,
        fromVisibleApplications: Bool = false
    ) throws -> WorkspaceConfig {
        guard fromVisibleApplications else {
            return try persist(name: name, hotkey: hotkey, apps: [])
        }
        return try create(
            name: name,
            hotkey: hotkey,
            applications: discovery.visibleDesktop().applications
        )
    }

    /// Creates a workspace from an explicit, user-reviewed set of visible apps.
    /// This is the menu-bar capture path: discovery proposes; the user decides.
    @discardableResult
    public func create(
        name: String,
        hotkey: String? = nil,
        applications: [LiveApplication]
    ) throws -> WorkspaceConfig {
        let apps = try appConfigs(from: applications)
        guard !apps.isEmpty else { throw WorkspaceAuthoringError.noVisibleApplications }

        return try persist(name: name, hotkey: hotkey, apps: apps)
    }

    /// Creates an empty, uniquely named workspace in one config transaction, so the name
    /// cannot collide with a workspace another EDN process added between naming and writing.
    @discardableResult
    public func createBlank(baseName: String = WorkspaceNaming.untitledBase) throws -> WorkspaceConfig {
        try configStore.update { config in
            let workspace = WorkspaceConfig(
                name: WorkspaceNaming.availableName(base: baseName, existing: config.workspaces.map(\.name)),
                number: Self.appendedNumber(in: config),
                hotkey: nil,
                apps: []
            )
            config.workspaces.append(workspace)
            return workspace
        }
    }

    private func persist(
        name: String,
        hotkey: String?,
        apps: [AppConfig]
    ) throws -> WorkspaceConfig {
        return try configStore.update { config in
            guard !config.workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw WorkspaceAuthoringError.workspaceAlreadyExists(name)
            }
            let workspace = WorkspaceConfig(name: name, number: Self.appendedNumber(in: config), hotkey: hotkey, apps: apps)
            config.workspaces.append(workspace)
            return workspace
        }
    }

    public func inspect(name: String) throws -> WorkspaceInspection {
        let config = try configStore.read()
        guard let workspace = config.workspaces.first(where: { $0.name == name }) else {
            throw WorkspaceAuthoringError.workspaceNotFound(name)
        }
        let state = try stateStore.read()
        return WorkspaceInspection(
            name: workspace.name,
            number: workspace.number,
            hotkey: workspace.hotkey,
            isActive: state.activeWorkspace == workspace.name,
            apps: workspace.apps.map { app in
                let remembered = state.windowFrames(workspace: workspace.name, key: app.stateKey) ?? []
                let configured = app.configuredFrames
                return InspectedApp(
                    bundleId: app.bundleId,
                    windowTitle: app.windowTitle,
                    configuredFrames: configured,
                    rememberedFrames: remembered,
                    effectiveFrames: remembered.isEmpty ? configured : remembered
                )
            }
        )
    }

    public func reset(name: String) throws {
        let config = try configStore.read()
        guard config.workspaces.contains(where: { $0.name == name }) else {
            throw WorkspaceAuthoringError.workspaceNotFound(name)
        }
        try stateStore.update { state in
            state.removeFrames(workspace: name)
        }
    }

    public func delete(name: String) throws {
        try configStore.update { config in
            guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else {
                throw WorkspaceAuthoringError.workspaceNotFound(name)
            }
            config.workspaces.remove(at: index)
        }
        try stateStore.update { state in
            state.removeFrames(workspace: name)
            if state.activeWorkspace == name {
                state.activeWorkspace = nil
            }
        }
    }

    /// Updates only workspace identity (name, hotkey). App membership is read inside the
    /// transaction and preserved exactly, including edits made by another process while
    /// the manager window was open. Position is structural, not identity -- it is never
    /// set here; renumbering happens automatically for every config write.
    @discardableResult
    public func updateMetadata(
        name: String,
        newName: String,
        hotkey: String?
    ) throws -> WorkspaceConfig {
        let workspace = try configStore.update { config -> WorkspaceConfig in
            guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else {
                throw WorkspaceAuthoringError.workspaceNotFound(name)
            }
            if config.workspaces.enumerated().contains(where: { otherIndex, workspace in
                otherIndex != index && workspace.name.caseInsensitiveCompare(newName) == .orderedSame
            }) {
                throw WorkspaceAuthoringError.workspaceAlreadyExists(newName)
            }
            let original = config.workspaces[index]
            let updated = WorkspaceConfig(
                name: newName,
                number: original.number,
                hotkey: hotkey,
                apps: original.apps
            )
            config.workspaces[index] = updated
            return updated
        }
        try stateStore.update { state in
            state.renameWorkspace(from: name, to: newName)
        }
        return workspace
    }

    /// Adds only the requested bundle ids to the latest config on disk. Existing app
    /// entries are never reconstructed from a potentially stale UI snapshot.
    @discardableResult
    public func addApplications(
        workspace name: String,
        bundleIds: Set<String>,
        availableApplications: [InstalledApplication]
    ) throws -> WorkspaceConfig {
        let available = Dictionary(
            availableApplications.map { ($0.bundleId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return try configStore.update { config in
            guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else {
                throw WorkspaceAuthoringError.workspaceNotFound(name)
            }
            var workspace = config.workspaces[index]
            let existing = Set(workspace.apps.map(\.bundleId))
            for bundleId in bundleIds.subtracting(existing).sorted() {
                guard available[bundleId] != nil else {
                    throw WorkspaceAuthoringError.applicationUnavailable(bundleId)
                }
                workspace.apps.append(AppConfig(bundleId: bundleId))
            }
            config.workspaces[index] = workspace
            return workspace
        }
    }

    /// Removes exactly the selected app identities from the latest config on disk and
    /// prunes only their remembered frames. Unrelated external edits survive.
    @discardableResult
    public func removeApplications(
        workspace name: String,
        stateKeys: Set<String>
    ) throws -> WorkspaceConfig {
        let workspace = try configStore.update { config in
            guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else {
                throw WorkspaceAuthoringError.workspaceNotFound(name)
            }
            var workspace = config.workspaces[index]
            workspace.apps.removeAll { stateKeys.contains($0.stateKey) }
            config.workspaces[index] = workspace
            return workspace
        }
        try stateStore.update { state in
            state.removeFrames(workspace: name, keys: stateKeys)
        }
        return workspace
    }

    /// Updates workspace metadata and explicit app membership. Existing app entries
    /// retain their config defaults and remembered layouts. Newly selected installed apps
    /// join without an implicit layout; opening and arranging them, then switching away,
    /// captures their positions automatically.
    @discardableResult
    public func update(
        name: String,
        newName: String,
        hotkey: String?,
        selectedBundleIds: Set<String>,
        availableApplications: [InstalledApplication]
    ) throws -> WorkspaceConfig {
        let availableBundleIds = Set(availableApplications.map(\.bundleId))
        let mutation = try configStore.update { config -> (workspace: WorkspaceConfig, removedKeys: [String]) in
            guard let index = config.workspaces.firstIndex(where: { $0.name == name }) else {
                throw WorkspaceAuthoringError.workspaceNotFound(name)
            }
            let original = config.workspaces[index]
            let retained = original.apps.filter { selectedBundleIds.contains($0.bundleId) }
            let retainedBundleIds = Set(retained.map(\.bundleId))
            let additionBundleIds = selectedBundleIds.subtracting(retainedBundleIds)
            let unresolved = additionBundleIds.subtracting(availableBundleIds)
            if let bundleId = unresolved.first {
                throw WorkspaceAuthoringError.applicationUnavailable(bundleId)
            }
            let additions = availableApplications
                .filter { additionBundleIds.contains($0.bundleId) }
                .map { AppConfig(bundleId: $0.bundleId) }
            let apps = retained + additions
            if config.workspaces.enumerated().contains(where: { otherIndex, workspace in
                otherIndex != index && workspace.name.caseInsensitiveCompare(newName) == .orderedSame
            }) {
                throw WorkspaceAuthoringError.workspaceAlreadyExists(newName)
            }
            let workspace = WorkspaceConfig(name: newName, number: original.number, hotkey: hotkey, apps: apps)
            config.workspaces[index] = workspace
            let removedKeys = original.apps
                .filter { !selectedBundleIds.contains($0.bundleId) }
                .map(\.stateKey)
            return (workspace, removedKeys)
        }

        try stateStore.update { state in
            state.renameWorkspace(from: name, to: newName)
            state.removeFrames(workspace: newName, keys: Set(mutation.removedKeys))
        }
        return mutation.workspace
    }

    /// Converts an explicit set of discovered apps into one replayable app-level entry
    /// per process. Multi-window apps are stored as a frame set; changing tab/document
    /// titles never changes which windows participate in the workspace.
    public func appConfigs(from applications: [LiveApplication]) throws -> [AppConfig] {
        var seenBundleIds: Set<String> = []
        var result: [AppConfig] = []

        for application in applications {
            guard seenBundleIds.insert(application.bundleId).inserted else {
                throw WorkspaceAuthoringError.duplicateApplicationProcess(application.bundleId)
            }
            if application.windows.count == 1, let window = application.windows.first {
                result.append(AppConfig(bundleId: application.bundleId, frame: window.frame))
                continue
            }
            result.append(AppConfig(
                bundleId: application.bundleId,
                frames: application.windows.map(\.frame)
            ))
        }

        return result
    }

    /// A number guaranteed to sort after every existing workspace, so a newly created one
    /// appends at the end of the row. `ConfigStore.update` renumbers 1...N immediately
    /// after this runs, so the exact value only needs to be "clearly last," not final.
    private static func appendedNumber(in config: Config) -> Int {
        (config.workspaces.map(\.number).max() ?? 0) + 1
    }
}
