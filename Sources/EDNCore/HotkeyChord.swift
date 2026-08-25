import Foundation

/// A compact, agent-editable global shortcut such as `cmd+[` or `ctrl+alt+l`.
/// Workspace shortcuts intentionally keep their simpler shared-prefix model; chords
/// are for global actions whose modifiers may differ from workspace switching.
public struct HotkeyChord: Equatable, Sendable {
    public let key: String
    public let modifierNames: [String]

    public init?(rawValue: String) {
        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.count >= 2, let rawKey = parts.last,
              let key = Self.normalizeKey(String(rawKey)) else { return nil }

        let modifiers = parts.dropLast().compactMap { Self.canonicalModifier($0) }
        guard modifiers.count == parts.count - 1,
              !modifiers.isEmpty,
              Set(modifiers).count == modifiers.count else { return nil }

        self.key = key
        modifierNames = Self.modifierOrder.filter { modifiers.contains($0) }
    }

    public init?(key: String, modifierNames: [String]) {
        self.init(rawValue: (modifierNames + [key]).joined(separator: "+"))
    }

    public var rawValue: String { (modifierNames + [key]).joined(separator: "+") }

    public var displayValue: String {
        let prefix = modifierNames.map {
            switch $0 {
            case "cmd": return "⌘"
            case "ctrl": return "⌃"
            case "alt": return "⌥"
            case "shift": return "⇧"
            default: return $0
            }
        }.joined()
        return prefix + key.uppercased()
    }

    public static func normalizeKey(_ value: String?) -> String? {
        let key = value?.lowercased() ?? ""
        guard key.count == 1, let character = key.first,
              (ShortcutKey.allowedCharacters + "[]").contains(character) else { return nil }
        return String(character)
    }

    private static let modifierOrder = ["ctrl", "alt", "shift", "cmd"]

    private static func canonicalModifier<S: StringProtocol>(_ value: S) -> String? {
        switch value {
        case "cmd", "command": return "cmd"
        case "ctrl", "control": return "ctrl"
        case "alt", "option": return "alt"
        case "shift": return "shift"
        default: return nil
        }
    }
}
