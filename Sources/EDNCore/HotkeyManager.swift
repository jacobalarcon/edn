import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers global hotkeys via Carbon's RegisterEventHotKey -- the same native,
/// zero-dependency API Rectangle/AeroSpace/FlashSpace all use. Works system-wide even
/// when the daemon isn't the frontmost app. RegisterEventHotKey itself does not require
/// Input Monitoring or Accessibility permission; EDN separately needs Accessibility
/// permission for its window-management work.
public final class HotkeyManager {
    public typealias Handler = (_ workspaceName: String) -> Void

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToWorkspace: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private let handler: Handler
    private var eventHandlerRef: EventHandlerRef?
    private var eventHandlerInstalled = false
    private static let signature: OSType = 0x65646E20 // 'edn '

    public init(handler: @escaping Handler) {
        self.handler = handler

        // A plain SwiftPM executable has no NSApplication event loop by default.
        // Carbon hotkey events are delivered through the application event dispatcher,
        // so initialize AppKit before obtaining its event target. Accessory policy keeps
        // the daemon out of the Dock and app switcher without requiring an .app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
        installEventHandler()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let name = manager.idToWorkspace[hotKeyID.id] {
                manager.handler(name)
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)

        if status != noErr {
            warn("failed to install Carbon hotkey event handler -- status \(status)")
        } else {
            eventHandlerInstalled = true
        }
    }

    /// Registers a hotkey for a workspace. `modifierNames` e.g. ["alt"], `key` e.g. "1".
    /// Silently-but-visibly skips (warns to stderr) rather than crashing on an unmapped
    /// key or a registration collision with another app's global hotkey.
    @discardableResult
    public func register(workspace name: String, key: String, modifierNames: [String]) -> Bool {
        guard eventHandlerInstalled else {
            warn("cannot register hotkey for workspace '\(name)' because the event handler is unavailable")
            return false
        }
        guard let keyCode = Self.keyCode(for: key) else {
            warn("no key mapping for '\(key)' -- skipping hotkey for workspace '\(name)'")
            return false
        }
        let modifiers = modifierNames.reduce(UInt32(0)) { $0 | Self.modifierMask(for: $1) }
        guard modifiers != 0 else {
            warn("no recognized modifier in \(modifierNames) -- skipping hotkey for workspace '\(name)'")
            return false
        }

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        guard status == noErr, let ref = hotKeyRef else {
            warn("failed to register hotkey (\(modifierNames.joined(separator: "+"))+\(key)) for workspace '\(name)' -- status \(status). Likely already claimed by another app.")
            return false
        }
        hotKeyRefs.append(ref)
        idToWorkspace[id] = name
        return true
    }

    /// Blocks forever, dispatching hotkey events as they arrive. Call once, at the end of setup.
    public func run() {
        // CFRunLoopRun alone does not dequeue and dispatch Carbon Event Manager events.
        // NSApplication.run provides the main application event loop needed by the
        // application event target used above, including for a bare executable.
        NSApplication.shared.run()
    }

    deinit {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write("edn: warning: \(message)\n".data(using: .utf8)!)
    }

    private static func modifierMask(for name: String) -> UInt32 {
        switch name.lowercased() {
        case "cmd", "command": return UInt32(cmdKey)
        case "alt", "option": return UInt32(optionKey)
        case "ctrl", "control": return UInt32(controlKey)
        case "shift": return UInt32(shiftKey)
        default: return 0
        }
    }

    private static func keyCode(for key: String) -> Int? {
        let digits: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9
        ]
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z
        ]
        let lower = key.lowercased()
        return digits[lower] ?? letters[lower]
    }
}
