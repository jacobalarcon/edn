import AppKit
import EDNCore

func shortcutPrefix(for modifierNames: [String]) -> String {
    modifierNames.map { name in
        switch name {
        case "cmd", "command": return "⌘"
        case "alt", "option": return "⌥"
        case "ctrl", "control": return "⌃"
        case "shift": return "⇧"
        default: return name
        }
    }.joined()
}

func modifierFlags(for names: [String]) -> NSEvent.ModifierFlags {
    names.reduce(into: []) { result, name in
        switch name {
        case "cmd", "command": result.insert(.command)
        case "alt", "option": result.insert(.option)
        case "ctrl", "control": result.insert(.control)
        case "shift": result.insert(.shift)
        default: break
        }
    }
}

protocol ShortcutRecorderDelegate: AnyObject {
    /// Capture brackets the window's global-hotkey suspension: while a recorder holds
    /// first responder, the very chord being recorded must not also switch workspaces.
    func shortcutRecorderDidBeginCapture(_ recorder: ShortcutRecorder)
    func shortcutRecorderDidEndCapture(_ recorder: ShortcutRecorder)
    func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord key: String?)
}

/// Raw key recorder. The recorded value comes from `charactersIgnoringModifiers`, so
/// ⌥2 stores "2" rather than the "™" the option layout would otherwise produce.
final class ShortcutRecorder: NSButton {
    weak var recorderDelegate: ShortcutRecorderDelegate?
    private(set) var shortcutKey: String?
    private var prefix: String
    private var isCapturing = false

    init(modifierNames: [String], key: String? = nil) {
        prefix = shortcutPrefix(for: modifierNames)
        shortcutKey = key
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        setAccessibilityLabel("Workspace shortcut")
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func setModifierNames(_ names: [String]) {
        prefix = shortcutPrefix(for: names)
        updateTitle()
    }

    /// Loads a value without reporting a change back; used when the selection changes.
    func setShortcutKey(_ key: String?) {
        shortcutKey = key
        updateTitle()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isCapturing = true
        updateTitle()
        recorderDelegate?.shortcutRecorderDidBeginCapture(self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isCapturing = false
        updateTitle()
        recorderDelegate?.shortcutRecorderDidEndCapture(self)
        return true
    }

    /// A modified chord such as ⌘V would otherwise be consumed by the main menu before
    /// the recorder ever sees a keyDown. While capturing, the recorder claims it first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if !record(event) { NSSound.beep() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcutKey = nil
            updateTitle()
            recorderDelegate?.shortcutRecorder(self, didRecord: nil)
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 48 || event.keyCode == 36 || event.keyCode == 53 {
            super.keyDown(with: event)
            return
        }
        if !record(event) { NSSound.beep() }
    }

    private func record(_ event: NSEvent) -> Bool {
        guard let value = ShortcutKey.normalize(event.charactersIgnoringModifiers) else {
            return false
        }
        shortcutKey = value
        updateTitle()
        recorderDelegate?.shortcutRecorder(self, didRecord: value)
        window?.makeFirstResponder(nil)
        return true
    }

    private func updateTitle() {
        if isCapturing {
            title = "Press a Key"
            return
        }
        title = shortcutKey.map { "\(prefix) \($0.uppercased())" } ?? "Record Shortcut"
    }
}

/// Records a complete global chord, including its own modifiers. Unlike workspace
/// shortcuts, focus controls do not inherit `hotkeyPrefix`, so ⌘[ and ⌘] can coexist
/// with ⌥1...⌥9 workspace switching.
final class GlobalShortcutRecorder: NSButton {
    var onCaptureChanged: ((Bool) -> Void)?
    var onShortcutChanged: ((String?) -> Void)?

    private(set) var shortcut: String?
    private var isCapturing = false

    init(accessibilityLabel: String) {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        setAccessibilityLabel(accessibilityLabel)
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func setShortcut(_ value: String?) {
        shortcut = value
        updateTitle()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isCapturing = true
        updateTitle()
        onCaptureChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isCapturing = false
        updateTitle()
        onCaptureChanged?(false)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if !record(event) { NSSound.beep() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcut = nil
            updateTitle()
            onShortcutChanged?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 48 || event.keyCode == 36 || event.keyCode == 53 {
            super.keyDown(with: event)
            return
        }
        if !record(event) { NSSound.beep() }
    }

    private func record(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("alt") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.command) { modifiers.append("cmd") }
        guard let key = HotkeyChord.normalizeKey(event.charactersIgnoringModifiers),
              let chord = HotkeyChord(key: key, modifierNames: modifiers) else { return false }
        shortcut = chord.rawValue
        updateTitle()
        onShortcutChanged?(chord.rawValue)
        window?.makeFirstResponder(nil)
        return true
    }

    private func updateTitle() {
        if isCapturing {
            title = "Press a Shortcut"
        } else if let shortcut, let chord = HotkeyChord(rawValue: shortcut) {
            title = chord.displayValue
        } else {
            title = "Record Shortcut"
        }
    }
}
