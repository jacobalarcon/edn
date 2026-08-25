import Foundation

public struct ConfigValidationError: Error, CustomStringConvertible, LocalizedError, Equatable {
    public let issues: [String]

    public init(issues: [String]) {
        self.issues = issues
    }

    public var description: String {
        "Invalid EDN config:\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
    }

    public var errorDescription: String? { description }
}

public extension Config {
    func validate() throws {
        var issues: [String] = []
        let allowedModifiers: Set<String> = ["cmd", "command", "alt", "option", "ctrl", "control", "shift"]
        let modifiers = general.modifierNames

        if modifiers.isEmpty || modifiers.contains(where: \.isEmpty) {
            issues.append("general.hotkeyPrefix must contain at least one modifier")
        }
        for modifier in modifiers where !allowedModifiers.contains(modifier) {
            issues.append("general.hotkeyPrefix contains unsupported modifier '\(modifier)'")
        }
        let canonicalModifiers = modifiers.map(Self.canonicalModifier)
        if Set(canonicalModifiers).count != canonicalModifiers.count {
            issues.append("general.hotkeyPrefix contains the same modifier more than once")
        }

        var workspaceNames: Set<String> = []
        var workspaceNumbers: Set<Int> = []
        var hotkeys: Set<String> = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let path = "workspaces[\(workspaceIndex)]"
            let trimmedName = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                issues.append("\(path).name must not be empty")
            } else if trimmedName != workspace.name {
                issues.append("\(path).name must not have leading or trailing whitespace")
            }
            if !workspaceNames.insert(trimmedName.lowercased()).inserted {
                issues.append("\(path).name duplicates workspace '\(workspace.name)' (names are case-insensitive)")
            }
            if workspace.number < 0 {
                issues.append("\(path).number must be zero or greater")
            }
            if !workspaceNumbers.insert(workspace.number).inserted {
                issues.append("\(path).number \(workspace.number) is already used by another workspace")
            }

            if let hotkey = workspace.hotkey {
                let normalized = hotkey.lowercased()
                if hotkey != hotkey.trimmingCharacters(in: .whitespacesAndNewlines) {
                    issues.append("\(path).hotkey must not have leading or trailing whitespace")
                }
                if normalized.count != 1 || !"0123456789abcdefghijklmnopqrstuvwxyz".contains(normalized) {
                    issues.append("\(path).hotkey '\(hotkey)' must be one ASCII letter or digit")
                }
                if !hotkeys.insert(normalized).inserted {
                    issues.append("\(path).hotkey '\(hotkey)' is already used by another workspace")
                }
            }

            var appKeys: Set<String> = []
            for (appIndex, app) in workspace.apps.enumerated() {
                let appPath = "\(path).apps[\(appIndex)]"
                let trimmedBundleID = app.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedBundleID.isEmpty {
                    issues.append("\(appPath).bundleId must not be empty")
                } else if trimmedBundleID != app.bundleId {
                    issues.append("\(appPath).bundleId must not have leading or trailing whitespace")
                }
                if let title = app.windowTitle {
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        issues.append("\(appPath).windowTitle must be omitted rather than empty")
                    } else if title != title.trimmingCharacters(in: .whitespacesAndNewlines) {
                        issues.append("\(appPath).windowTitle must not have leading or trailing whitespace")
                    }
                }
                if !appKeys.insert(app.stateKey.lowercased()).inserted {
                    issues.append("\(appPath) duplicates another app/window identity in workspace '\(workspace.name)'")
                }
                if let frame = app.frame {
                    Self.validate(frame: frame, path: "\(appPath).frame", issues: &issues)
                }
                if app.frame != nil, app.frames != nil {
                    issues.append("\(appPath) must use either frame or frames, not both")
                }
                if let frames = app.frames {
                    if frames.isEmpty {
                        issues.append("\(appPath).frames must contain at least one frame when present")
                    }
                    for (frameIndex, frame) in frames.enumerated() {
                        Self.validate(frame: frame, path: "\(appPath).frames[\(frameIndex)]", issues: &issues)
                    }
                }
            }
        }

        if !issues.isEmpty {
            throw ConfigValidationError(issues: issues)
        }
    }

    private static func canonicalModifier(_ modifier: String) -> String {
        switch modifier {
        case "command": return "cmd"
        case "option": return "alt"
        case "control": return "ctrl"
        default: return modifier
        }
    }

    private static func validate(frame: Frame, path: String, issues: inout [String]) {
        if !frame.x.isFinite || !frame.y.isFinite || !frame.w.isFinite || !frame.h.isFinite {
            issues.append("\(path) values must be finite numbers")
        }
        if frame.w <= 0 || frame.h <= 0 {
            issues.append("\(path) width and height must be greater than zero")
        }
    }
}
