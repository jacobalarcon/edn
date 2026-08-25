import Foundation

/// Transactional access to the hand-edited EDN config. External editor changes are
/// reloaded for every operation, and invalid mutations never reach disk.
public struct ConfigStore {
    public let url: URL

    public init(url: URL = Config.defaultPath) {
        self.url = url
    }

    public func read() throws -> Config {
        try CoordinatedFileAccess.read(lockURL: lockURL) {
            try Config.load(from: url)
        }
    }

    public func update<Result>(_ body: (inout Config) throws -> Result) throws -> Result {
        try CoordinatedFileAccess.write(lockURL: lockURL) {
            var config = try Config.load(from: url)
            let result = try body(&config)
            // Every write leaves workspace numbers contiguous, matching row position --
            // this also self-heals any config written before that invariant existed.
            config.renumberContiguously()
            try config.validate()
            try config.save(to: url)
            return result
        }
    }

    private var lockURL: URL {
        url.appendingPathExtension("lock")
    }
}
