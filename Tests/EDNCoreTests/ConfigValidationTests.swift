import Foundation
import Testing
@testable import EDNCore

@Suite("Configuration validation")
struct ConfigValidationTests {
    @Test("Accepts distinct workspaces and combined modifiers")
    func acceptsValidConfig() throws {
        let config = Config(
            general: GeneralConfig(hotkeyPrefix: "cmd+alt"),
            workspaces: [
                WorkspaceConfig(name: "browser", number: 1, hotkey: "1", apps: [
                    AppConfig(bundleId: "com.google.Chrome", frame: Frame(x: -100, y: 20, w: 1200, h: 900))
                ]),
                WorkspaceConfig(name: "terminal", number: 2, hotkey: "t", apps: [
                    AppConfig(bundleId: "com.mitchellh.ghostty", windowTitle: "project")
                ])
            ]
        )

        try config.validate()
    }

    @Test("Rejects ambiguous workspace, hotkey, and app identities")
    func rejectsDuplicateIdentities() throws {
        let config = Config(workspaces: [
            WorkspaceConfig(name: "Work", number: 1, hotkey: "A", apps: [
                AppConfig(bundleId: "com.example.App", windowTitle: "Main"),
                AppConfig(bundleId: "com.example.App", windowTitle: "main")
            ]),
            WorkspaceConfig(name: "work", number: 1, hotkey: "a")
        ])

        do {
            try config.validate()
            Issue.record("Expected validation to fail")
        } catch let error as ConfigValidationError {
            #expect(error.issues.count == 4)
        }
    }

    @Test("Rejects unsupported modifiers and unusable frames")
    func rejectsInvalidValues() throws {
        let config = Config(
            general: GeneralConfig(hotkeyPrefix: "hyper"),
            workspaces: [
                WorkspaceConfig(name: "bad", number: -1, hotkey: "F1", apps: [
                    AppConfig(bundleId: "", frame: Frame(x: 0, y: 0, w: 0, h: -1), windowTitle: " ")
                ])
            ]
        )

        do {
            try config.validate()
            Issue.record("Expected validation to fail")
        } catch let error as ConfigValidationError {
            #expect(error.issues.count >= 6)
        }
    }

    @Test("Loading from disk validates before returning config")
    func loadRejectsInvalidConfig() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-invalid-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"general":{"hotkeyPrefix":"alt"},"workspaces":[{"apps":[],"name":"","number":1}]}"#
        try Data(json.utf8).write(to: url)

        do {
            _ = try Config.load(from: url)
            Issue.record("Expected disk config validation to fail")
        } catch is ConfigValidationError {}
    }

    @Test("Accepts multi-window frame sets and rejects conflicting frame forms")
    func validatesWindowFrameSets() throws {
        let frames = [
            Frame(x: 0, y: 0, w: 600, h: 800),
            Frame(x: 600, y: 0, w: 600, h: 800)
        ]
        try Config(workspaces: [
            WorkspaceConfig(name: "multi", number: 1, apps: [
                AppConfig(bundleId: "app.browser", frames: frames)
            ])
        ]).validate()

        do {
            try Config(workspaces: [
                WorkspaceConfig(name: "invalid", number: 1, apps: [
                    AppConfig(bundleId: "app.browser", frame: frames[0], frames: frames)
                ])
            ]).validate()
            Issue.record("Expected conflicting frame and frames values to fail")
        } catch is ConfigValidationError {}
    }

    @Test("External atomic config edits invalidate the process cache")
    func externalConfigEditInvalidatesCache() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edn-config-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Config(workspaces: [WorkspaceConfig(name: "before", number: 1)]).save(to: url)
        #expect(try Config.load(from: url).workspaces[0].name == "before")

        let edited = Config(workspaces: [WorkspaceConfig(name: "after", number: 1)])
        let encoder = JSONEncoder()
        let data = try encoder.encode(edited)
        // Simulate an editor rather than Config.save(), which explicitly invalidates.
        try data.write(to: url, options: .atomic)

        #expect(try Config.load(from: url).workspaces[0].name == "after")
    }
}
