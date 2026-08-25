import AppKit
import EDNCore

protocol FocusSettingsHost: AnyObject {
    func focusSettingsSetHotkeysSuspended(_ suspended: Bool)
    func focusSettingsDidMutateConfiguration()
}

final class FocusSettingsWindowController: NSWindowController, NSWindowDelegate {
    private enum Binding { case previousApp, nextApp, previousWindow, nextWindow }

    weak var host: FocusSettingsHost?

    private let previousWindowRecorder = GlobalShortcutRecorder(accessibilityLabel: "Focus previous window shortcut")
    private let nextWindowRecorder = GlobalShortcutRecorder(accessibilityLabel: "Focus next window shortcut")
    private let previousAppRecorder = GlobalShortcutRecorder(accessibilityLabel: "Focus previous app shortcut")
    private let nextAppRecorder = GlobalShortcutRecorder(accessibilityLabel: "Focus next app shortcut")
    private let shortcutWarning = NSTextField(wrappingLabelWithString: "")
    private var isLoading = false

    init(host: FocusSettingsHost) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 335),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        self.host = host
        window.delegate = self
        window.contentView = makeContentView()
        connectRecorders()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 335))

        let title = NSTextField(labelWithString: "Focus")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let explanation = wrappingLabel(
            "Move focus through the active workspace. EDN does not launch apps, move windows, or change workspaces."
        )
        explanation.textColor = .secondaryLabelColor

        let windowsTitle = sectionLabel("Windows")
        let windowGrid = NSGridView(views: [
            [rightLabel("Previous Window"), previousWindowRecorder],
            [rightLabel("Next Window"), nextWindowRecorder]
        ])
        configure(grid: windowGrid)

        let appsTitle = sectionLabel("Apps")
        let appGrid = NSGridView(views: [
            [rightLabel("Previous App"), previousAppRecorder],
            [rightLabel("Next App"), nextAppRecorder]
        ])
        configure(grid: appGrid)

        shortcutWarning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutWarning.maximumNumberOfLines = 0

        let stack = NSStackView(views: [
            title, explanation, windowsTitle, windowGrid, appsTitle, appGrid, shortcutWarning
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: explanation)
        stack.setCustomSpacing(5, after: windowsTitle)
        stack.setCustomSpacing(14, after: windowGrid)
        stack.setCustomSpacing(5, after: appsTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for recorder in allRecorders {
            recorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        explanation.widthAnchor.constraint(equalToConstant: 440).isActive = true
        shortcutWarning.widthAnchor.constraint(equalToConstant: 440).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30)
        ])
        return container
    }

    private func connectRecorders() {
        for recorder in allRecorders {
            recorder.onCaptureChanged = { [weak self] capturing in
                self?.host?.focusSettingsSetHotkeysSuspended(capturing)
            }
        }
        previousWindowRecorder.onShortcutChanged = { [weak self] value in
            self?.save(.previousWindow, value: value)
        }
        nextWindowRecorder.onShortcutChanged = { [weak self] value in
            self?.save(.nextWindow, value: value)
        }
        previousAppRecorder.onShortcutChanged = { [weak self] value in
            self?.save(.previousApp, value: value)
        }
        nextAppRecorder.onShortcutChanged = { [weak self] value in
            self?.save(.nextApp, value: value)
        }
    }

    private func reload() {
        do {
            let focus = try Config.load().general.focus
            isLoading = true
            previousWindowRecorder.setShortcut(focus.previousWindow)
            nextWindowRecorder.setShortcut(focus.nextWindow)
            previousAppRecorder.setShortcut(focus.previousApp)
            nextAppRecorder.setShortcut(focus.nextApp)
            refreshWarning()
            isLoading = false
        } catch {
            isLoading = false
            present(error)
        }
    }

    private func save(_ binding: Binding, value: String?) {
        guard !isLoading else { return }
        do {
            try ConfigStore().update { config in
                switch binding {
                case .previousApp: config.general.focus.previousApp = value
                case .nextApp: config.general.focus.nextApp = value
                case .previousWindow: config.general.focus.previousWindow = value
                case .nextWindow: config.general.focus.nextWindow = value
                }
            }
            host?.focusSettingsDidMutateConfiguration()
            reload()
        } catch {
            reload()
            present(error)
        }
    }

    private func refreshWarning() {
        let overridesBackForward = allRecorders.contains { recorder in
            guard let value = recorder.shortcut, let chord = HotkeyChord(rawValue: value) else { return false }
            return chord.modifierNames == ["cmd"] && (chord.key == "[" || chord.key == "]")
        }
        if overridesBackForward {
            shortcutWarning.stringValue = "⌘[ and ⌘] override Back and Forward in browsers, Finder, Preview, and other apps. Press Delete while recording to clear a shortcut."
            shortcutWarning.textColor = .systemOrange
        } else {
            shortcutWarning.stringValue = "Global shortcuts take priority over the same shortcuts in other apps. Press Delete while recording to clear one."
            shortcutWarning.textColor = .secondaryLabelColor
        }
    }

    private var allRecorders: [GlobalShortcutRecorder] {
        [previousWindowRecorder, nextWindowRecorder, previousAppRecorder, nextAppRecorder]
    }

    private func configure(grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
    }

    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private func present(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        host?.focusSettingsSetHotkeysSuspended(false)
    }

    private func rightLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.alignment = .right
        return label
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        return label
    }
}
