import Foundation
import Testing
@testable import EDNCore

@Suite("Global hotkey chords")
struct HotkeyChordTests {
    @Test("Parses aliases and writes one canonical representation")
    func canonicalization() {
        let chord = HotkeyChord(rawValue: "command+option+[")
        #expect(chord?.key == "[")
        #expect(chord?.modifierNames == ["alt", "cmd"])
        #expect(chord?.rawValue == "alt+cmd+[")
        #expect(chord?.displayValue == "⌥⌘[")
    }

    @Test("Rejects unmodified, duplicated, unsupported, and composed keys")
    func rejection() {
        #expect(HotkeyChord(rawValue: "[") == nil)
        #expect(HotkeyChord(rawValue: "cmd+command+[") == nil)
        #expect(HotkeyChord(rawValue: "hyper+[") == nil)
        #expect(HotkeyChord(rawValue: "cmd+™") == nil)
    }

    @Test("Legacy configs decode without focus settings")
    func backwardCompatibility() throws {
        let data = Data(#"{"general":{"hotkeyPrefix":"alt"},"workspaces":[]}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: data)
        #expect(config.general.focus == FocusConfig())
    }

    @Test("Focus shortcuts validate and cannot collide with workspace shortcuts")
    func validation() throws {
        let valid = Config(
            general: GeneralConfig(focus: FocusConfig(
                previousApp: "ctrl+alt+1",
                nextApp: "ctrl+alt+2",
                previousWindow: "cmd+[",
                nextWindow: "cmd+]"
            )),
            workspaces: [WorkspaceConfig(name: "one", number: 1, hotkey: "1")]
        )
        try valid.validate()

        let collision = Config(
            general: GeneralConfig(
                hotkeyPrefix: "cmd",
                focus: FocusConfig(previousApp: "cmd+1", nextApp: "cmd+]")
            ),
            workspaces: [WorkspaceConfig(name: "one", number: 1, hotkey: "1")]
        )
        #expect(throws: ConfigValidationError.self) { try collision.validate() }
    }
}
