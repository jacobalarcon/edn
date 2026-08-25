import Foundation

public struct AppConfig: Codable, Equatable {
    public var bundleId: String
    public var frame: Frame?
    /// Starting layout for an app with multiple standard windows. The frames are an
    /// unordered app-level set; EDN does not claim that any one frame permanently
    /// identifies a particular document window.
    public var frames: [Frame]?
    /// Optional substring match against the window's title, for apps that may have
    /// multiple windows open (e.g. several terminal or browser windows). When nil,
    /// the first window (by a stable, deterministic ordering) is used.
    public var windowTitle: String?

    public init(bundleId: String, frame: Frame? = nil, frames: [Frame]? = nil, windowTitle: String? = nil) {
        self.bundleId = bundleId
        self.frame = frame
        self.frames = frames
        self.windowTitle = windowTitle
    }

    public var configuredFrames: [Frame] {
        if let frames { return frames }
        if let frame { return [frame] }
        return []
    }

    /// Key used to store/look up this app's frame in WorkspaceState. Bundle ID alone
    /// isn't enough once windowTitle disambiguates multiple windows of the same app --
    /// two AppConfig entries with the same bundleId but different windowTitle values
    /// would otherwise silently overwrite each other's saved frame.
    public var stateKey: String {
        guard let windowTitle, !windowTitle.isEmpty else { return bundleId }
        return "\(bundleId)::\(windowTitle)"
    }
}

/// A workspace is just a named, hand-picked set of apps + saved frames.
/// No layout computation, no auto-detected display profiles -- if you use a
/// different screen, make a second workspace (e.g. "coding-laptop") and switch
/// to it yourself.
public struct WorkspaceConfig: Codable, Equatable {
    public var name: String
    public var number: Int
    public var hotkey: String?
    public var apps: [AppConfig]

    public init(name: String, number: Int, hotkey: String? = nil, apps: [AppConfig] = []) {
        self.name = name; self.number = number; self.hotkey = hotkey; self.apps = apps
    }
}

public struct GeneralConfig: Codable, Equatable {
    public var hotkeyPrefix: String

    public init(hotkeyPrefix: String = "alt") {
        self.hotkeyPrefix = hotkeyPrefix
    }

    /// Supports a single modifier (`alt`) or combinations (`cmd+alt`) while keeping
    /// the on-disk format compact and easy to edit by hand or by an agent.
    public var modifierNames: [String] {
        hotkeyPrefix
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

public struct Config: Codable, Equatable {
    public var general: GeneralConfig
    public var workspaces: [WorkspaceConfig]

    public init(general: GeneralConfig = GeneralConfig(), workspaces: [WorkspaceConfig] = []) {
        self.general = general
        self.workspaces = workspaces
    }

    public static var defaultPath: URL {
        if let override = ProcessInfo.processInfo.environment["EDN_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return builtInDefaultPath
    }

    private static var builtInDefaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/edn/config.json")
    }

    public static var legacyPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tiler/config.json")
    }

    public static func load(from url: URL = defaultPath) throws -> Config {
        if ProcessInfo.processInfo.environment["EDN_CONFIG_PATH"] == nil,
           url.standardizedFileURL == builtInDefaultPath.standardizedFileURL {
            _ = try StorageMigration.migrateConfigIfNeeded()
        }
        // A missing config is the normal first-run state. Keep it in memory until the
        // user creates a workspace; the first authoring transaction writes the file.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Config()
        }
        return try ConfigCache.shared.load(from: url) {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(Config.self, from: data)
            try config.validate()
            return config
        }
    }

    /// Keeps `number` meaning exactly one thing: position in the row, always contiguous
    /// 1...N. It is never independently set by any authoring call -- create appends past
    /// the current max so new workspaces sort last, delete leaves the rest in relative
    /// order, and this reassigns 1...N to match. Also self-heals any config written
    /// before this invariant existed (e.g. numbers that were made to match hotkeys),
    /// since it always re-derives from a stable sort rather than trusting existing gaps.
    /// Hotkeys are untouched -- position and shortcut are unrelated by design.
    mutating func renumberContiguously() {
        workspaces = workspaces
            .sorted { $0.number < $1.number }
            .enumerated()
            .map { index, workspace in
                var workspace = workspace
                workspace.number = index + 1
                return workspace
            }
    }

    public func save(to url: URL = defaultPath) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        ConfigCache.shared.invalidate(url: url)
    }

    public static func example() -> Config {
        Config(
            general: GeneralConfig(hotkeyPrefix: "alt"),
            workspaces: [
                WorkspaceConfig(
                    name: "coding-big",
                    number: 1,
                    hotkey: "1",
                    apps: [
                        AppConfig(bundleId: "com.microsoft.VSCode", frame: Frame(x: 0, y: 25, w: 1600, h: 1415)),
                        AppConfig(bundleId: "com.googlecode.iterm2", frame: Frame(x: 1600, y: 25, w: 960, h: 700)),
                        AppConfig(bundleId: "com.google.Chrome", frame: Frame(x: 1600, y: 725, w: 960, h: 715))
                    ]
                ),
                WorkspaceConfig(
                    name: "coding-laptop",
                    number: 2,
                    hotkey: "2",
                    apps: [
                        AppConfig(bundleId: "com.microsoft.VSCode", frame: Frame(x: 0, y: 25, w: 1512, h: 907))
                    ]
                )
            ]
        )
    }
}

private struct ConfigFileSignature: Equatable {
    let fileResourceIdentifier: String?
    let contentModificationDate: Date?
    let fileSize: Int?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey])
        fileResourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }
        contentModificationDate = values.contentModificationDate
        fileSize = values.fileSize
    }
}

private final class ConfigCache {
    static let shared = ConfigCache()

    private let lock = NSLock()
    private var values: [URL: (signature: ConfigFileSignature, config: Config)] = [:]

    func load(from url: URL, decode: () throws -> Config) throws -> Config {
        let standardized = url.standardizedFileURL
        let signatureBeforeRead = try ConfigFileSignature(url: standardized)
        lock.lock()
        if let cached = values[standardized], cached.signature == signatureBeforeRead {
            lock.unlock()
            EDNInstrumentation.trace("config cache hit \(standardized.path)")
            return cached.config
        }
        lock.unlock()

        let config = try decode()
        let signatureAfterRead = try ConfigFileSignature(url: standardized)
        // An editor may atomically replace the file between the signature check and
        // decode. Never associate bytes read from one version with another version's
        // cache signature; return this valid decode uncached and reload next time.
        guard signatureBeforeRead == signatureAfterRead else {
            EDNInstrumentation.trace("config changed during read \(standardized.path); bypassing cache")
            return config
        }
        lock.lock()
        values[standardized] = (signatureAfterRead, config)
        lock.unlock()
        EDNInstrumentation.trace("config cache miss \(standardized.path)")
        return config
    }

    func invalidate(url: URL) {
        lock.lock()
        values.removeValue(forKey: url.standardizedFileURL)
        lock.unlock()
    }
}
