import AppKit
import Foundation

public enum FocusDirection: String, Codable, Equatable, Sendable {
    case previous
    case next
}

public enum FocusTarget: String, Codable, Equatable, Sendable {
    case app
    case window
}

public struct WorkspaceFocusResult: Codable, Equatable, Sendable {
    public let workspace: String
    public let bundleId: String
    public let direction: FocusDirection
    public let target: FocusTarget
    public let windowTitle: String?

    public init(
        workspace: String,
        bundleId: String,
        direction: FocusDirection,
        target: FocusTarget = .app,
        windowTitle: String? = nil
    ) {
        self.workspace = workspace
        self.bundleId = bundleId
        self.direction = direction
        self.target = target
        self.windowTitle = windowTitle
    }
}

public enum WorkspaceFocusError: Error, CustomStringConvertible, Equatable {
    case noActiveWorkspace
    case workspaceNotFound(String)
    case noRunningApplications(String)
    case noFocusableWindows(String)
    case focusFailed(String)

    public var description: String {
        switch self {
        case .noActiveWorkspace:
            return "No active EDN workspace."
        case .workspaceNotFound(let name):
            return "Workspace '\(name)' is active in state but missing from config."
        case .noRunningApplications(let name):
            return "Workspace '\(name)' has no running applications to focus."
        case .noFocusableWindows(let name):
            return "Workspace '\(name)' has no visible windows to focus."
        case .focusFailed(let bundleId):
            return "macOS refused to focus '\(bundleId)'."
        }
    }
}

public protocol ApplicationFocusing {
    var frontmostBundleId: String? { get }
    var runningBundleIds: Set<String> { get }
    func focus(bundleId: String) -> Bool
    func windows(bundleId: String) -> [any ManagedWindow]
    func focus(window: any ManagedWindow, bundleId: String) -> Bool
}

public extension ApplicationFocusing {
    func windows(bundleId: String) -> [any ManagedWindow] { [] }
    func focus(window: any ManagedWindow, bundleId: String) -> Bool { false }
}

public struct SystemApplicationFocuser: ApplicationFocusing {
    public init() {}

    public var frontmostBundleId: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public var runningBundleIds: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.activationPolicy == .regular else { return nil }
            return application.bundleIdentifier
        })
    }

    public func focus(bundleId: String) -> Bool {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleId
        }) else { return false }
        return application.activate(options: [.activateIgnoringOtherApps])
    }

    public func windows(bundleId: String) -> [any ManagedWindow] {
        AXWindowManager.windows(forBundleID: bundleId).map { $0 as any ManagedWindow }
    }

    public func focus(window: any ManagedWindow, bundleId: String) -> Bool {
        let appReady = frontmostBundleId == bundleId || focus(bundleId: bundleId)
        return appReady && window.focus()
    }
}

/// Cycles only through running members of the active EDN workspace. It does not launch,
/// hide, move, snapshot, or switch anything; focus is the entire operation.
public struct WorkspaceFocusController {
    private let configURL: URL
    private let stateStore: WorkspaceStateStore
    private let applications: any ApplicationFocusing

    public init(
        configURL: URL = Config.defaultPath,
        stateStore: WorkspaceStateStore = WorkspaceStateStore(),
        applications: any ApplicationFocusing = SystemApplicationFocuser()
    ) {
        self.configURL = configURL
        self.stateStore = stateStore
        self.applications = applications
    }

    @discardableResult
    public func focus(_ direction: FocusDirection) throws -> WorkspaceFocusResult {
        let (workspace, candidates) = try activeWorkspaceAndRunningApps()
        let activeName = workspace.name
        guard !candidates.isEmpty else {
            throw WorkspaceFocusError.noRunningApplications(activeName)
        }

        let target: String
        if let current = applications.frontmostBundleId,
           let index = candidates.firstIndex(of: current) {
            switch direction {
            case .next: target = candidates[(index + 1) % candidates.count]
            case .previous: target = candidates[(index - 1 + candidates.count) % candidates.count]
            }
        } else {
            target = direction == .next ? candidates[0] : candidates[candidates.count - 1]
        }

        guard applications.focus(bundleId: target) else {
            throw WorkspaceFocusError.focusFailed(target)
        }
        return WorkspaceFocusResult(workspace: activeName, bundleId: target, direction: direction)
    }

    /// Traverses the active workspace in two stable levels: explicit app order first,
    /// then each app's live standard windows in title/position order. Nothing is saved;
    /// the set is rebuilt on every keypress, so this does not imply persistent ownership.
    @discardableResult
    public func focusWindow(_ direction: FocusDirection) throws -> WorkspaceFocusResult {
        let (workspace, runningApps) = try activeWorkspaceAndRunningApps()
        let candidates: [(bundleId: String, window: any ManagedWindow)] = runningApps.flatMap { bundleId in
            applications.windows(bundleId: bundleId).filter {
                $0.subrole == kAXStandardWindowSubrole && !$0.isMinimized && $0.frame != nil
            }.map { (bundleId, $0) }
        }
        guard !candidates.isEmpty else {
            throw WorkspaceFocusError.noFocusableWindows(workspace.name)
        }

        let frontmost = applications.frontmostBundleId
        let focusedIndex = candidates.firstIndex {
            $0.bundleId == frontmost && $0.window.isMain
        }
        let index: Int
        if let focusedIndex {
            switch direction {
            case .next: index = (focusedIndex + 1) % candidates.count
            case .previous: index = (focusedIndex - 1 + candidates.count) % candidates.count
            }
        } else {
            index = direction == .next ? 0 : candidates.count - 1
        }
        let target = candidates[index]
        guard applications.focus(window: target.window, bundleId: target.bundleId) else {
            throw WorkspaceFocusError.focusFailed(target.bundleId)
        }
        return WorkspaceFocusResult(
            workspace: workspace.name,
            bundleId: target.bundleId,
            direction: direction,
            target: .window,
            windowTitle: target.window.title
        )
    }

    private func activeWorkspaceAndRunningApps() throws -> (WorkspaceConfig, [String]) {
        let state = try stateStore.read()
        guard let activeName = state.activeWorkspace else {
            throw WorkspaceFocusError.noActiveWorkspace
        }
        let config = try Config.load(from: configURL)
        guard let workspace = config.workspaces.first(where: { $0.name == activeName }) else {
            throw WorkspaceFocusError.workspaceNotFound(activeName)
        }
        var seen: Set<String> = []
        let running = applications.runningBundleIds
        let candidates = workspace.apps
            .map(\.bundleId)
            .filter { seen.insert($0).inserted && running.contains($0) }
        return (workspace, candidates)
    }
}
