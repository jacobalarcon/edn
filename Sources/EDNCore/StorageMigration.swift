import Foundation

public struct StorageMigrationResult: Equatable {
    public let kind: String
    public let source: URL
    public let destination: URL

    public init(kind: String, source: URL, destination: URL) {
        self.kind = kind
        self.source = source
        self.destination = destination
    }
}

/// Moves Tiler-era storage into EDN's paths without deleting or overwriting anything.
/// The old files remain in place as a rollback copy. Migration is idempotent: once an
/// EDN file exists, it is always treated as authoritative.
public enum StorageMigration {
    public static func migrateLegacyFilesIfNeeded() throws -> [StorageMigrationResult] {
        var results: [StorageMigrationResult] = []
        if ProcessInfo.processInfo.environment["EDN_CONFIG_PATH"] == nil,
           try migrateConfigIfNeeded() {
            results.append(StorageMigrationResult(kind: "config", source: Config.legacyPath, destination: Config.defaultPath))
        }
        if ProcessInfo.processInfo.environment["EDN_STATE_PATH"] == nil,
           try migrateStateIfNeeded() {
            results.append(StorageMigrationResult(kind: "state", source: WorkspaceState.legacyPath, destination: WorkspaceState.defaultPath))
        }
        return results
    }

    @discardableResult
    public static func migrateConfigIfNeeded() throws -> Bool {
        try copyIfNeeded(from: Config.legacyPath, to: Config.defaultPath)
    }

    @discardableResult
    public static func migrateStateIfNeeded() throws -> Bool {
        try copyIfNeeded(from: WorkspaceState.legacyPath, to: WorkspaceState.defaultPath)
    }

    /// Internal entry point kept path-based so migration behavior can be tested without
    /// reading or writing the user's real configuration.
    @discardableResult
    static func copyIfNeeded(from source: URL, to destination: URL, fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else {
            return false
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Data(contentsOf: source)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        // Publish a fully-written file without a check-then-overwrite race. A hard link
        // creates the destination directory entry atomically and fails if it already
        // exists, while the temporary file lives on the same volume by construction.
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.linkItem(at: temporary, to: destination)
            return true
        } catch {
            // Another EDN process may have completed migration after the guards above.
            // Its destination wins; never overwrite it with the legacy file.
            if fileManager.fileExists(atPath: destination.path) {
                return false
            }
            throw error
        }
    }
}
