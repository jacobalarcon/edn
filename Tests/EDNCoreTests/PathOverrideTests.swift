import Foundation
import Testing
@testable import EDNCore

@Suite("Environment path overrides", .serialized)
struct PathOverrideTests {
    @Test("Default paths can be isolated with EDN_CONFIG_PATH and EDN_STATE_PATH")
    func defaultPathsUseEnvironmentOverrides() {
        let configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-config-\(UUID().uuidString).json")
        let statePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-state-\(UUID().uuidString).json")
        let oldConfigPath = getenv("EDN_CONFIG_PATH").map { String(cString: $0) }
        let oldStatePath = getenv("EDN_STATE_PATH").map { String(cString: $0) }
        defer {
            restoreEnvironment("EDN_CONFIG_PATH", oldValue: oldConfigPath)
            restoreEnvironment("EDN_STATE_PATH", oldValue: oldStatePath)
        }

        setenv("EDN_CONFIG_PATH", configPath.path, 1)
        setenv("EDN_STATE_PATH", statePath.path, 1)

        #expect(Config.defaultPath.standardizedFileURL == configPath.standardizedFileURL)
        #expect(WorkspaceState.defaultPath.standardizedFileURL == statePath.standardizedFileURL)
    }

    private func restoreEnvironment(_ name: String, oldValue: String?) {
        if let oldValue {
            setenv(name, oldValue, 1)
        } else {
            unsetenv(name)
        }
    }
}
