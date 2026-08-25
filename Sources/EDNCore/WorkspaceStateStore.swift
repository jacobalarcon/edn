import Foundation

/// File-backed state access serialized across EDN processes. Atomic replacement keeps
/// each individual JSON write intact; this lock makes the entire read-modify-write cycle
/// atomic so the menu app, daemon, and CLI cannot overwrite one another's newer state.
public struct WorkspaceStateStore {
    public let url: URL

    public init(url: URL = WorkspaceState.defaultPath) {
        self.url = url
    }

    public func read() throws -> WorkspaceState {
        try CoordinatedFileAccess.read(lockURL: lockURL) {
            try WorkspaceState.load(from: url)
        }
    }

    public func update<Result>(_ body: (inout WorkspaceState) throws -> Result) throws -> Result {
        try CoordinatedFileAccess.write(lockURL: lockURL) {
            var state = try WorkspaceState.load(from: url)
            let result = try body(&state)
            try state.save(to: url)
            return result
        }
    }

    private var lockURL: URL {
        url.appendingPathExtension("lock")
    }
}
