import Foundation
import EDNCore

setvbuf(stdout, nil, _IONBF, 0)

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String), invalidValue(String), confirmationRequired(String)
    var description: String {
        switch self {
        case .missingValue(let value): return "Missing value for \(value)."
        case .invalidValue(let value): return value
        case .confirmationRequired(let value): return "\(value) changes saved data; rerun with --yes."
        }
    }
}

struct ErrorBody: Encodable { let code: String; let message: String; let command: String? }
struct ErrorEnvelope: Encodable { let error: ErrorBody }
struct InitResponse: Encodable { let configPath: String; let created: Bool }
struct StatusResponse: Encodable { let accessibilityTrusted: Bool; let configPath: String; let statePath: String }
struct WorkspaceSummary: Encodable {
    let name: String; let number: Int; let hotkey: String?; let appCount: Int; let isActive: Bool
}
struct WorkspaceListResponse: Encodable { let activeWorkspace: String?; let workspaces: [WorkspaceSummary] }
struct FrameApplyResponse: Encodable {
    let requested: Frame; let actual: Frame?; let positionMatched: Bool; let sizeMatched: Bool; let fullyMatched: Bool
}
struct SwitchIssueResponse: Encodable { let code: String; let expected: Int; let actual: Int }
struct AppSwitchResponse: Encodable {
    let bundleId: String; let activation: String; let succeeded: Bool
    let frames: [FrameApplyResponse]; let issue: SwitchIssueResponse?
}
struct SwitchResponse: Encodable { let workspace: String; let apps: [AppSwitchResponse] }
struct SaveResponse: Encodable {
    let workspace: String; let captured: [String]; let missing: [String]; let fullyCaptured: Bool
}
struct MutationResponse: Encodable { let action: String; let workspace: String }
struct DaemonHotkeyResponse: Encodable { let workspace: String; let shortcut: String }
struct DaemonFocusHotkeyResponse: Encodable {
    let target: FocusTarget
    let direction: FocusDirection
    let shortcut: String
}
struct DaemonReadyResponse: Encodable {
    let event: String
    let hotkeys: [DaemonHotkeyResponse]
    let focusHotkeys: [DaemonFocusHotkeyResponse]
}
struct DaemonSwitchResponse: Encodable { let event: String; let result: SwitchResponse }
struct DaemonFocusResponse: Encodable { let event: String; let result: WorkspaceFocusResult }
struct DaemonErrorResponse: Encodable { let event: String; let workspace: String?; let error: ErrorBody }

func printUsage() {
    print("""
    edn - virtual macOS workspaces that put your windows back where you left them

    Usage:
      edn init [--json]            Create an empty config at ~/.config/edn/config.json
      edn list [--json]            List configured workspaces
      edn windows [--json]         Show visible apps, windows, frames, and displays
      edn create <name> [options]  Options: --hotkey K, --from-visible, --json
      edn inspect <name> [--json]  Show configured, remembered, and effective layout
      edn switch <name> [--json]   Switch to a workspace
      edn save [name] [--json]     Snapshot current window frames
      edn reset <name> --yes [--json]
                                  Forget remembered frames
      edn delete <name> --yes [--json]
                                  Delete a workspace from config and state
      edn status [--json]          Show Accessibility permission status
      edn focus <next|previous> [--window] [--json]
                                  Focus an app or live window in the active workspace
      edn daemon [--json]          Listen for hotkeys; --json emits an event stream
    """)
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

func encodedJSON<Value: Encodable>(_ value: Value, pretty: Bool) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func writeJSON<Value: Encodable>(
    _ value: Value,
    to handle: FileHandle = .standardOutput,
    pretty: Bool = true
) throws {
    var data = try encodedJSON(value, pretty: pretty)
    data.append(0x0A)
    handle.write(data)
}

func writeText(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((text + "\n").utf8))
}

func errorBody(_ error: Error, command: String?) -> ErrorBody {
    let code: String
    switch error {
    case CLIError.missingValue: code = "missing_value"
    case CLIError.invalidValue: code = "invalid_arguments"
    case CLIError.confirmationRequired: code = "confirmation_required"
    case EngineError.notTrusted: code = "accessibility_not_trusted"
    case EngineError.workspaceNotFound: code = "workspace_not_found"
    case EngineError.workspaceActivationFailed: code = "workspace_activation_failed"
    case WorkspaceAuthoringError.workspaceAlreadyExists: code = "workspace_already_exists"
    case WorkspaceAuthoringError.workspaceNotFound: code = "workspace_not_found"
    case WorkspaceAuthoringError.noVisibleApplications: code = "no_visible_applications"
    case WorkspaceAuthoringError.applicationUnavailable: code = "application_unavailable"
    case WorkspaceAuthoringError.duplicateApplicationProcess: code = "duplicate_application_process"
    case WorkspaceAuthoringError.ambiguousWindows: code = "ambiguous_windows"
    case WorkspaceFocusError.noActiveWorkspace: code = "no_active_workspace"
    case WorkspaceFocusError.workspaceNotFound: code = "workspace_not_found"
    case WorkspaceFocusError.noRunningApplications: code = "no_running_applications"
    case WorkspaceFocusError.noFocusableWindows: code = "no_focusable_windows"
    case WorkspaceFocusError.focusFailed: code = "focus_failed"
    case is ConfigValidationError: code = "invalid_config"
    default: code = "command_failed"
    }
    return ErrorBody(code: code, message: String(describing: error), command: command)
}

func fail(_ error: Error, command: String?, json: Bool) -> Never {
    if json {
        let envelope = ErrorEnvelope(error: errorBody(error, command: command))
        if (try? writeJSON(envelope, to: .standardError)) == nil {
            writeText("{\"error\":{\"code\":\"encoding_failed\",\"message\":\"Could not encode CLI error.\"}}", to: .standardError)
        }
    } else {
        writeText("Error: \(error)", to: .standardError)
    }
    exit(1)
}

func frameText(_ frame: Frame?) -> String {
    guard let frame else { return "none" }
    return "x=\(frame.x) y=\(frame.y) w=\(frame.w) h=\(frame.h)"
}

func activationName(_ activation: AppActivationResult) -> String {
    switch activation {
    case .activated: return "activated"
    case .launched: return "launched"
    case .applicationNotFound: return "application_not_found"
    case .launchTimedOut: return "launch_timed_out"
    case .failed: return "failed"
    }
}

func switchResponse(workspace: String, results: [SwitchResult]) -> SwitchResponse {
    SwitchResponse(workspace: workspace, apps: results.map { result in
        let issue: SwitchIssueResponse?
        switch result.issue {
        case .windowCountMismatch(let expected, let actual):
            issue = SwitchIssueResponse(code: "window_count_mismatch", expected: expected, actual: actual)
        case nil:
            issue = nil
        }
        return AppSwitchResponse(
            bundleId: result.bundleId,
            activation: activationName(result.activation),
            succeeded: result.appWasPresented && issue == nil,
            frames: result.applies.map {
                FrameApplyResponse(
                    requested: $0.requested,
                    actual: $0.actual,
                    positionMatched: $0.positionMatched,
                    sizeMatched: $0.sizeMatched,
                    fullyMatched: $0.fullyMatched
                )
            },
            issue: issue
        )
    })
}

let commandLineArguments = Array(CommandLine.arguments.dropFirst())
let jsonRequested = commandLineArguments.contains("--json")
guard let command = commandLineArguments.first else {
    printUsage()
    exit(0)
}
let arguments = Array(commandLineArguments.dropFirst())

do {
    for migration in try StorageMigration.migrateLegacyFilesIfNeeded() {
        writeText(
            "edn: migrated \(migration.kind) from \(migration.source.path) to \(migration.destination.path) (legacy file preserved)",
            to: .standardError
        )
    }
} catch {
    writeText("edn: warning: legacy storage migration failed: \(error)", to: .standardError)
}

switch command {
case "status":
    do {
        try validateOptions(in: arguments, afterPositionals: 0, flags: ["--json"])
        let response = StatusResponse(
            accessibilityTrusted: AXWindowManager.isTrusted,
            configPath: Config.defaultPath.path,
            statePath: WorkspaceState.defaultPath.path
        )
        if jsonRequested { try writeJSON(response) }
        else { print(response.accessibilityTrusted ? "Accessibility: TRUSTED" : "Accessibility: NOT TRUSTED") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "init":
    do {
        try validateOptions(in: arguments, afterPositionals: 0, flags: ["--json"])
        let path = Config.defaultPath
        let created = !FileManager.default.fileExists(atPath: path.path)
        if created { try Config().save(to: path) }
        if jsonRequested { try writeJSON(InitResponse(configPath: path.path, created: created)) }
        else if created { print("Created empty config at \(path.path)") }
        else { print("Config already exists at \(path.path)") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "list":
    do {
        try validateOptions(in: arguments, afterPositionals: 0, flags: ["--json"])
        let config = try Config.load()
        let active = try WorkspaceStateStore().read().activeWorkspace
        let workspaces = config.workspaces.sorted(by: { $0.number < $1.number })
        if jsonRequested {
            try writeJSON(WorkspaceListResponse(
                activeWorkspace: active,
                workspaces: workspaces.map {
                    WorkspaceSummary(
                        name: $0.name,
                        number: $0.number,
                        hotkey: $0.hotkey,
                        appCount: $0.apps.count,
                        isActive: $0.name == active
                    )
                }
            ))
        } else {
            for workspace in workspaces {
                let hotkey = workspace.hotkey.map { " [\($0)]" } ?? ""
                print("\(workspace.number). \(workspace.name)\(hotkey) - \(workspace.apps.count) app(s)")
            }
        }
    } catch { fail(error, command: command, json: jsonRequested) }

case "windows":
    do {
        try validateOptions(in: arguments, afterPositionals: 0, flags: ["--json"])
        let snapshot = try SystemWorkspaceDiscovery().visibleDesktop()
        if jsonRequested { try writeJSON(snapshot) }
        else {
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
    } catch { fail(error, command: command, json: jsonRequested) }

case "create":
    do {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn create <name> [--hotkey K] [--from-visible] [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, valueOptions: ["--hotkey"], flags: ["--from-visible", "--json"])
        let workspace = try WorkspaceAuthor().create(
            name: name,
            hotkey: try optionValue("--hotkey", in: arguments),
            fromVisibleApplications: arguments.contains("--from-visible")
        )
        if jsonRequested { try writeJSON(workspace) }
        else { print("Created workspace '\(workspace.name)' as number \(workspace.number) with \(workspace.apps.count) app/window entry(s).") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "inspect":
    do {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn inspect <name> [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, flags: ["--json"])
        let inspection = try WorkspaceAuthor().inspect(name: name)
        if jsonRequested { try writeJSON(inspection) }
        else {
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
    } catch { fail(error, command: command, json: jsonRequested) }

case "switch":
    do {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn switch <workspace-name> [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, flags: ["--json"])
        let results = try WorkspaceEngine(config: Config.load()).switchTo(name)
        if jsonRequested { try writeJSON(switchResponse(workspace: name, results: results)) }
        else { for result in results { print(result.summary) } }
    } catch { fail(error, command: command, json: jsonRequested) }

case "save":
    do {
        let positionalCount = arguments.first.map { $0.hasPrefix("--") ? 0 : 1 } ?? 0
        try validateOptions(in: arguments, afterPositionals: positionalCount, flags: ["--json"])
        let engine = WorkspaceEngine(config: try Config.load())
        let explicitName = positionalCount == 1 ? arguments.first : nil
        guard let name = try explicitName ?? engine.activeWorkspace() else {
            throw CLIError.invalidValue("No active workspace to save. Usage: edn save <workspace-name> [--json]")
        }
        let result = try engine.snapshot(workspace: name)
        if jsonRequested {
            try writeJSON(SaveResponse(
                workspace: result.workspace,
                captured: result.captured,
                missing: result.missing,
                fullyCaptured: result.fullyCaptured
            ))
        } else {
            print("Saved layouts for \(result.captured.count) app(s) in workspace '\(name)'")
            if !result.missing.isEmpty {
                writeText("edn: warning: could not capture: \(result.missing.joined(separator: ", "))", to: .standardError)
            }
        }
        if !result.fullyCaptured { exit(1) }
    } catch { fail(error, command: command, json: jsonRequested) }

case "reset":
    do {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn reset <name> --yes [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, flags: ["--yes", "--json"])
        guard arguments.contains("--yes") else { throw CLIError.confirmationRequired("reset") }
        try WorkspaceAuthor().reset(name: name)
        if jsonRequested { try writeJSON(MutationResponse(action: "reset", workspace: name)) }
        else { print("Reset remembered frames for workspace '\(name)'.") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "delete":
    do {
        guard let name = arguments.first, !name.hasPrefix("--") else {
            throw CLIError.invalidValue("Usage: edn delete <name> --yes [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, flags: ["--yes", "--json"])
        guard arguments.contains("--yes") else { throw CLIError.confirmationRequired("delete") }
        try WorkspaceAuthor().delete(name: name)
        if jsonRequested { try writeJSON(MutationResponse(action: "delete", workspace: name)) }
        else { print("Deleted workspace '\(name)' from config and state.") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "focus":
    do {
        guard let value = arguments.first, !value.hasPrefix("--"),
              let direction = FocusDirection(rawValue: value.lowercased()) else {
            throw CLIError.invalidValue("Usage: edn focus <next|previous> [--json]")
        }
        try validateOptions(in: arguments, afterPositionals: 1, flags: ["--window", "--json"])
        let controller = WorkspaceFocusController()
        let result = arguments.contains("--window")
            ? try controller.focusWindow(direction)
            : try controller.focus(direction)
        if jsonRequested { try writeJSON(result) }
        else { print("Focused \(result.bundleId) in workspace '\(result.workspace)'.") }
    } catch { fail(error, command: command, json: jsonRequested) }

case "daemon":
    do {
        try validateOptions(in: arguments, afterPositionals: 0, flags: ["--json"])
        guard AXWindowManager.isTrusted else { throw EngineError.notTrusted }
        let config = try Config.load()
        let engine = WorkspaceEngine(config: config)
        let switchQueue = DispatchQueue(label: "edn.switch")
        let switchCoordinator = WorkspaceSwitchCoordinator(queue: switchQueue) { name in
            do {
                try engine.reloadConfig()
                let results = try engine.switchTo(name)
                let response = switchResponse(workspace: name, results: results)
                if jsonRequested { try writeJSON(DaemonSwitchResponse(event: "switch", result: response), pretty: false) }
                else { for result in results { print(result.summary) } }
            } catch {
                if jsonRequested {
                    try? writeJSON(
                        DaemonErrorResponse(event: "error", workspace: name, error: errorBody(error, command: "daemon")),
                        to: .standardError,
                        pretty: false
                    )
                } else { writeText("Error switching to '\(name)': \(error)", to: .standardError) }
            }
        }
        let focusController = WorkspaceFocusController()
        let hotkeys = HotkeyManager { action in
            switch action {
            case .workspace(let name):
                switchCoordinator.request(name)
            case .focusPreviousApp, .focusNextApp, .focusPreviousWindow, .focusNextWindow:
                let direction: FocusDirection = switch action {
                case .focusPreviousApp, .focusPreviousWindow: .previous
                default: .next
                }
                let target: FocusTarget = switch action {
                case .focusPreviousWindow, .focusNextWindow: .window
                default: .app
                }
                switchQueue.async {
                    do {
                        let result = target == .app
                            ? try focusController.focus(direction)
                            : try focusController.focusWindow(direction)
                        if jsonRequested {
                            try writeJSON(DaemonFocusResponse(event: "focus", result: result), pretty: false)
                        } else {
                            print("Focused \(result.bundleId) in workspace '\(result.workspace)'.")
                        }
                    } catch WorkspaceFocusError.noActiveWorkspace,
                            WorkspaceFocusError.noRunningApplications,
                            WorkspaceFocusError.noFocusableWindows {
                        // Focus on an empty context is deliberately a quiet no-op.
                    } catch {
                        if jsonRequested {
                            try? writeJSON(
                                DaemonErrorResponse(event: "error", workspace: nil, error: errorBody(error, command: "daemon")),
                                to: .standardError,
                                pretty: false
                            )
                        } else { writeText("Error changing focus: \(error)", to: .standardError) }
                    }
                }
            }
        }
        let modifierNames = config.general.modifierNames
        let modifierLabel = modifierNames.joined(separator: "+")
        var registered: [DaemonHotkeyResponse] = []
        var registeredFocus: [DaemonFocusHotkeyResponse] = []
        for workspace in config.workspaces {
            guard let key = workspace.hotkey else { continue }
            if hotkeys.register(workspace: workspace.name, key: key, modifierNames: modifierNames) {
                registered.append(DaemonHotkeyResponse(workspace: workspace.name, shortcut: "\(modifierLabel)+\(key)"))
            }
        }
        for (raw, action, target, direction) in [
            (config.general.focus.previousApp, HotkeyAction.focusPreviousApp, FocusTarget.app, FocusDirection.previous),
            (config.general.focus.nextApp, HotkeyAction.focusNextApp, FocusTarget.app, FocusDirection.next),
            (config.general.focus.previousWindow, HotkeyAction.focusPreviousWindow, FocusTarget.window, FocusDirection.previous),
            (config.general.focus.nextWindow, HotkeyAction.focusNextWindow, FocusTarget.window, FocusDirection.next)
        ] {
            guard let raw, let chord = HotkeyChord(rawValue: raw) else { continue }
            if hotkeys.register(action: action, key: chord.key, modifierNames: chord.modifierNames) {
                registeredFocus.append(DaemonFocusHotkeyResponse(target: target, direction: direction, shortcut: chord.rawValue))
            }
        }
        if jsonRequested {
            try writeJSON(
                DaemonReadyResponse(event: "ready", hotkeys: registered, focusHotkeys: registeredFocus),
                pretty: false
            )
        }
        else if registered.isEmpty && registeredFocus.isEmpty {
            print("No global shortcuts are configured. Add one in EDN and restart.")
        }
        else {
            print("edn daemon running. Hotkeys:")
            for hotkey in registered { print("  \(hotkey.shortcut) -> \(hotkey.workspace)") }
            for hotkey in registeredFocus {
                print("  \(hotkey.shortcut) -> focus \(hotkey.direction.rawValue) \(hotkey.target.rawValue)")
            }
        }
        hotkeys.run()
    } catch { fail(error, command: command, json: jsonRequested) }

default:
    let error = CLIError.invalidValue("Unknown command '\(command)'.")
    if jsonRequested { fail(error, command: command, json: true) }
    printUsage()
    exit(1)
}
