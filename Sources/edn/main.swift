import Foundation
import EDNCore

// Unbuffered stdout: `edn daemon` is long-running and often piped to a log file,
// where fully-buffered stdio would otherwise delay (or lose, on a hard kill) output.
setvbuf(stdout, nil, _IONBF, 0)

do {
    for migration in try StorageMigration.migrateLegacyFilesIfNeeded() {
        FileHandle.standardError.write(
            "edn: migrated \(migration.kind) from \(migration.source.path) to \(migration.destination.path) (legacy file preserved)\n"
                .data(using: .utf8)!
        )
    }
} catch {
    FileHandle.standardError.write("edn: warning: legacy storage migration failed: \(error)\n".data(using: .utf8)!)
}

func printUsage() {
    print("""
    edn - instant, config-driven workspaces with remembered window layouts for macOS

    Usage:
      edn init                   Write an example config to ~/.config/edn/config.json
      edn list                   List configured workspaces
      edn windows [--json]       Show visible apps, windows, frames, and displays
      edn create <name> [options]
                                 Create a workspace; options: --hotkey K,
                                 --from-visible, --json
      edn inspect <name> [--json]
                                 Show configured, remembered, and effective layout
      edn switch <name>          Switch to a workspace (hide others, activate + position its apps)
      edn save [name]            Snapshot a workspace's current window frames to state
      edn reset <name> --yes     Forget remembered frames and return to config defaults
      edn delete <name> --yes    Delete a workspace from config and state
      edn status                 Show Accessibility permission status
      edn daemon                 Run in the background, listening for configured hotkeys
    """)
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String)
    case confirmationRequired(String)

    var description: String {
        switch self {
        case .missingValue(let option): return "Missing value for \(option)."
        case .invalidValue(let message): return message
        case .confirmationRequired(let command): return "\(command) changes saved data; rerun with --yes."
        }
    }
}

func optionValue(_ option: String, in arguments: [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: option) else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex, !arguments[valueIndex].hasPrefix("--") else {
        throw CLIError.missingValue(option)
    }
    return arguments[valueIndex]
}

func validateOptions(
    in arguments: [String],
    afterPositionals positionalCount: Int,
    valueOptions: Set<String> = [],
    flags: Set<String> = []
) throws {
    var seen: Set<String> = []
    var index = positionalCount
    while index < arguments.count {
        let argument = arguments[index]
        guard valueOptions.contains(argument) || flags.contains(argument) else {
            throw CLIError.invalidValue("Unknown option '\(argument)'.")
        }
        guard seen.insert(argument).inserted else {
            throw CLIError.invalidValue("Option '\(argument)' was provided more than once.")
        }
        if valueOptions.contains(argument) {
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                throw CLIError.missingValue(argument)
            }
            index += 2
        } else {
            index += 1
        }
    }
}

func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

func frameText(_ frame: Frame?) -> String {
    guard let frame else { return "none" }
    return "x=\(frame.x) y=\(frame.y) w=\(frame.w) h=\(frame.h)"
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    printUsage()
    exit(0)
}

switch command {
case "status":
    print(AXWindowManager.isTrusted ? "Accessibility: TRUSTED" : "Accessibility: NOT TRUSTED")
    if !AXWindowManager.isTrusted {
        AXWindowManager.requestPermission()
    }

case "init":
    let path = Config.defaultPath
    if FileManager.default.fileExists(atPath: path.path) {
        print("Config already exists at \(path.path)")
    } else {
        do {
            try Config.example().save(to: path)
            print("Wrote example config to \(path.path)")
        } catch {
            print("Failed to write config: \(error)")
            exit(1)
        }
    }

case "list":
    do {
        let config = try Config.load()
        for ws in config.workspaces.sorted(by: { $0.number < $1.number }) {
            let hotkey = ws.hotkey.map { " [\($0)]" } ?? ""
            print("\(ws.number). \(ws.name)\(hotkey) - \(ws.apps.count) app(s)")
        }
    } catch {
        print("Failed to load config (\(Config.defaultPath.path)): \(error)")
        print("Run 'edn init' to create one.")
        exit(1)
    }

case "windows":
    do {
        let commandArguments = Array(args.dropFirst())
        try validateOptions(in: commandArguments, afterPositionals: 0, flags: ["--json"])
        let snapshot = try SystemWorkspaceDiscovery().visibleDesktop()
        if commandArguments.contains("--json") {
            try printJSON(snapshot)
        } else {
            print("Displays:")
            for display in snapshot.displays {
                let main = display.isMain ? " [main]" : ""
                print("  \(display.id): \(display.name)\(main) — \(frameText(display.frame))")
            }
            print("Visible applications:")
            for app in snapshot.applications {
                print("  \(app.name) (\(app.bundleId), pid \(app.processId))")
                for window in app.windows {
                    let display = window.displayId.map { " display=\($0)" } ?? ""
                    print("    \"\(window.title)\" — \(frameText(window.frame))\(display)")
                }
            }
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "create":
    do {
        let commandArguments = Array(args.dropFirst())
        guard let name = commandArguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn create <name> [--hotkey K] [--from-visible] [--json]")
        }
        try validateOptions(
            in: commandArguments,
            afterPositionals: 1,
            valueOptions: ["--hotkey"],
            flags: ["--from-visible", "--json"]
        )
        // Position in the row is structural, not something a caller sets: a new
        // workspace always appends after the last one. See Config.renumberContiguously.
        let workspace = try WorkspaceAuthor().create(
            name: name,
            hotkey: try optionValue("--hotkey", in: commandArguments),
            fromVisibleApplications: commandArguments.contains("--from-visible")
        )
        if commandArguments.contains("--json") {
            try printJSON(workspace)
        } else {
            print("Created workspace '\(workspace.name)' as number \(workspace.number) with \(workspace.apps.count) app/window entry(s).")
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "inspect":
    do {
        let commandArguments = Array(args.dropFirst())
        guard let name = commandArguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn inspect <name> [--json]")
        }
        try validateOptions(in: commandArguments, afterPositionals: 1, flags: ["--json"])
        let inspection = try WorkspaceAuthor().inspect(name: name)
        if commandArguments.contains("--json") {
            try printJSON(inspection)
        } else {
            let active = inspection.isActive ? " [active]" : ""
            print("\(inspection.number). \(inspection.name)\(active) hotkey=\(inspection.hotkey ?? "none")")
            for app in inspection.apps {
                let title = app.windowTitle.map { " title=\"\($0)\"" } ?? ""
                print("  \(app.bundleId)\(title)")
                print("    configured: \(app.configuredFrames.map { frameText($0) }.joined(separator: "; "))")
                print("    remembered: \(app.rememberedFrames.map { frameText($0) }.joined(separator: "; "))")
                print("    effective:  \(app.effectiveFrames.map { frameText($0) }.joined(separator: "; "))")
            }
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "switch":
    guard let name = args.dropFirst().first else {
        print("Usage: edn switch <workspace-name>")
        exit(1)
    }
    do {
        let config = try Config.load()
        let engine = WorkspaceEngine(config: config)
        let results = try engine.switchTo(name)
        for result in results {
            print(result.summary)
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "save":
    do {
        let config = try Config.load()
        let engine = WorkspaceEngine(config: config)
        guard let name = try args.dropFirst().first ?? engine.activeWorkspace() else {
            print("No active workspace to save. Usage: edn save <workspace-name>")
            exit(1)
        }
        let result = try engine.snapshot(workspace: name)
        print("Saved layouts for \(result.captured.count) app(s) in workspace '\(name)'")
        if !result.missing.isEmpty {
            FileHandle.standardError.write(
                "edn: warning: could not capture: \(result.missing.joined(separator: ", "))\n".data(using: .utf8)!
            )
            exit(1)
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "reset":
    do {
        let commandArguments = Array(args.dropFirst())
        guard let name = commandArguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn reset <name> --yes")
        }
        try validateOptions(in: commandArguments, afterPositionals: 1, flags: ["--yes"])
        guard commandArguments.contains("--yes") else {
            throw CLIError.confirmationRequired("reset")
        }
        try WorkspaceAuthor().reset(name: name)
        print("Reset remembered frames for workspace '\(name)'.")
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "delete":
    do {
        let commandArguments = Array(args.dropFirst())
        guard let name = commandArguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn delete <name> --yes")
        }
        try validateOptions(in: commandArguments, afterPositionals: 1, flags: ["--yes"])
        guard commandArguments.contains("--yes") else {
            throw CLIError.confirmationRequired("delete")
        }
        try WorkspaceAuthor().delete(name: name)
        print("Deleted workspace '\(name)' from config and state.")
    } catch {
        print("Error: \(error)")
        exit(1)
    }

case "daemon":
    guard AXWindowManager.isTrusted else {
        print("Accessibility not trusted. Run 'edn status' to trigger the permission prompt, grant it, then retry.")
        exit(1)
    }
    do {
        let config = try Config.load()
        let engine = WorkspaceEngine(config: config)
        // All switch work runs serially off Carbon's callback thread so a hung app's
        // AX call can't stall hotkey delivery for the rest of the workspaces.
        let switchQueue = DispatchQueue(label: "edn.switch")
        let switchCoordinator = WorkspaceSwitchCoordinator(queue: switchQueue) { name in
            do {
                try engine.reloadConfig() // pick up valid config edits without restarting the daemon
                let results = try engine.switchTo(name)
                for result in results { print(result.summary) }
            } catch {
                print("Error switching to '\(name)': \(error)")
            }
        }
        let hotkeys = HotkeyManager { name in switchCoordinator.request(name) }

        let modifierNames = config.general.modifierNames
        let modifierLabel = modifierNames.joined(separator: "+")
        var registered: [String] = []
        for ws in config.workspaces {
            guard let key = ws.hotkey else { continue }
            if hotkeys.register(workspace: ws.name, key: key, modifierNames: modifierNames) {
                registered.append("\(modifierLabel)+\(key) -> \(ws.name)")
            }
        }

        if registered.isEmpty {
            print("No workspaces have a hotkey configured. Add \"hotkey\": \"1\" etc. to a workspace and restart.")
        } else {
            print("edn daemon running. Hotkeys:")
            for line in registered { print("  \(line)") }
        }
        hotkeys.run()
    } catch {
        print("Error: \(error)")
        exit(1)
    }

default:
    printUsage()
    exit(1)
}
