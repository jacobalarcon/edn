import Foundation

/// Auto-managed snapshot of last-known window frames, keyed by workspace name then by
/// AppConfig.stateKey (bundle id, or bundle id + window title for disambiguated windows).
/// Not meant to be hand-edited. Saved state takes precedence over a workspace's config
/// frame once it exists -- config is only the starting default for a workspace's first
/// switch; after that, wherever you actually leave the window wins. See WorkspaceEngine.switchTo.
public struct WorkspaceState: Codable, Equatable {
    public var frames: [String: [String: Frame]] // workspace name -> AppConfig.stateKey -> frame
    /// App-level window sets. Optional for backward-compatible decoding of state files
    /// written before EDN learned to replay every window belonging to an app.
    public var windowSets: [String: [String: [Frame]]]?
    /// The workspace active as of the last switch, shared by one-shot CLI commands and
    /// the long-running daemon through the state file.
    public var activeWorkspace: String?
    /// When `activeWorkspace` became active. Used to tell a genuinely user-dragged frame
    /// apart from EDN's own window move still settling -- see WorkspaceEngine.switchTo's
    /// dwell-time guard on snapshotting the outgoing workspace.
    public var activeWorkspaceSince: Date?

    public init(
        frames: [String: [String: Frame]] = [:],
        windowSets: [String: [String: [Frame]]]? = nil,
        activeWorkspace: String? = nil,
        activeWorkspaceSince: Date? = nil
    ) {
        self.frames = frames
        self.windowSets = windowSets
        self.activeWorkspace = activeWorkspace
        self.activeWorkspaceSince = activeWorkspaceSince
    }

    public static var defaultPath: URL {
        if let override = ProcessInfo.processInfo.environment["EDN_STATE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return builtInDefaultPath
    }

    private static var builtInDefaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/edn/state.json")
    }

    public static var legacyPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/tiler/state.json")
    }

    /// Loads state, or an empty default if the file doesn't exist yet (normal on first run).
    /// If the file exists but fails to decode (corruption), the bad file is preserved
    /// alongside a `.corrupt` copy and a warning is printed rather than silently discarding it.
    public static func load(from url: URL = defaultPath) throws -> WorkspaceState {
        if ProcessInfo.processInfo.environment["EDN_STATE_PATH"] == nil,
           url.standardizedFileURL == builtInDefaultPath.standardizedFileURL {
            _ = try StorageMigration.migrateStateIfNeeded()
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WorkspaceState() // no file yet -- normal, not an error
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(WorkspaceState.self, from: data)
        } catch {
            let corruptCopy = url.appendingPathExtension("corrupt")
            // Never replace corrupt state with a fresh file unless its original bytes
            // have first been preserved successfully for diagnosis and recovery.
            try data.write(to: corruptCopy, options: .atomic)
            warn("state file at \(url.path) is corrupt (\(error)); starting fresh. Bad copy saved to \(corruptCopy.path)")
            return WorkspaceState()
        }
    }

    /// Writes state atomically and reports failure to the caller instead of swallowing it,
    /// since silent state loss directly undermines the "remembers exactly" promise.
    public func save(to url: URL = defaultPath) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public mutating func setFrame(_ frame: Frame, workspace: String, key: String) {
        frames[workspace, default: [:]][key] = frame
    }

    public func frame(workspace: String, key: String) -> Frame? {
        frames[workspace]?[key]
    }

    public mutating func setWindowFrames(_ values: [Frame], workspace: String, key: String) {
        var sets = windowSets ?? [:]
        sets[workspace, default: [:]][key] = values
        windowSets = sets
        // Preserve a useful first frame for older EDN binaries and state readers.
        if let first = values.first {
            frames[workspace, default: [:]][key] = first
        } else {
            frames[workspace]?[key] = nil
        }
    }

    public func windowFrames(workspace: String, key: String) -> [Frame]? {
        if let values = windowSets?[workspace]?[key] { return values }
        return frame(workspace: workspace, key: key).map { [$0] }
    }

    public mutating func removeFrames(workspace: String) {
        frames.removeValue(forKey: workspace)
        windowSets?.removeValue(forKey: workspace)
    }

    public mutating func renameWorkspace(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        if let oldFrames = frames.removeValue(forKey: oldName) {
            frames[newName] = oldFrames
        }
        if let oldWindowSets = windowSets?.removeValue(forKey: oldName) {
            windowSets?[newName] = oldWindowSets
        }
        if activeWorkspace == oldName {
            activeWorkspace = newName
        }
    }

    public mutating func removeFrames(workspace: String, keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys {
            frames[workspace]?[key] = nil
            windowSets?[workspace]?[key] = nil
        }
        if frames[workspace]?.isEmpty == true {
            frames.removeValue(forKey: workspace)
        }
        if windowSets?[workspace]?.isEmpty == true {
            windowSets?.removeValue(forKey: workspace)
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write("edn: warning: \(message)\n".data(using: .utf8)!)
    }
}
