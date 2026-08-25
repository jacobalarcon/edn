import AppKit
import EDNCore
import Foundation
import OSLog
import ServiceManagement

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WorkspaceManagerHost, FocusSettingsHost {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let workspaceIndicator = WorkspaceIndicatorView()
    private let logger = Logger(subsystem: "com.jacobalarcon.edn", category: "lifecycle")
    private let switchQueue = DispatchQueue(label: "edn.menu.switch")
    private let discoveryQueue = DispatchQueue(label: "edn.menu.discovery", qos: .userInitiated)
    private var hotkeys: HotkeyManager?
    private var configSignature: String?
    private var didSaveOnTermination = false
    private var hotkeysSuspended = false
    private var didOfferAccessibilityThisLaunch = false
    private var accessibilityPollTimer: Timer?
    private var resumeWorkItem: DispatchWorkItem?
    /// Bundle IDs launched by an in-flight EDN switch. Their workspace-switch replay
    /// already handled them, so the subsequent NSWorkspace launch notification is ignored.
    /// Access only from switchQueue.
    private var launchesHandledBySwitch: [String: Date] = [:]
    private var manager: WorkspaceManagerWindowController?
    private var focusSettings: FocusSettingsWindowController?
    private var cachedInstalledApplications: [InstalledApplication]?
    private var lastSwitchIssues: [(workspace: String, bundleId: String, issue: SwitchIssue)] = []
    private lazy var switchCoordinator = WorkspaceSwitchCoordinator(queue: switchQueue) { [weak self] name in
        self?.switchImmediately(to: name)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        installWorkspaceIndicator()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceSessionResumed(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceSessionResumed(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        reloadHotkeysIfNeeded(force: true)
        refreshStatusTitle()

        let needsFirstWorkspace = (try? Config.load().workspaces.isEmpty) == true
            && !FileManager.default.fileExists(atPath: Config.defaultPath.path)
        if needsFirstWorkspace {
            DispatchQueue.main.async { [weak self] in
                self?.presentManager(beginningCreate: false)
            }
        }
        if !AXWindowManager.isTrusted {
            DispatchQueue.main.async { [weak self] in
                self?.offerAccessibilitySetupIfNeeded()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        workspaceIndicator.isMenuHighlighted = true
        reloadHotkeysIfNeeded()
        rebuildMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        workspaceIndicator.isMenuHighlighted = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish any in-flight switch before deciding which workspace and geometry
        // should be captured. AppKit activation and AX work remain serialized.
        switchQueue.sync {
            saveActiveWorkspaceForTerminationIfNeeded()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveActiveWorkspaceForTerminationIfNeeded()
    }

    // MARK: - Menu

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        do {
            let config = try Config.load()
            let active = try WorkspaceStateStore().read().activeWorkspace
            for workspace in config.workspaces.sorted(by: { $0.number < $1.number }) {
                let item = NSMenuItem(
                    title: "\(workspace.number)  \(workspace.name)",
                    action: #selector(switchWorkspace(_:)),
                    keyEquivalent: workspace.hotkey ?? ""
                )
                item.target = self
                item.representedObject = workspace.name
                item.state = workspace.name == active ? .on : .off
                if workspace.hotkey != nil {
                    item.keyEquivalentModifierMask = modifierFlags(for: config.general.modifierNames)
                }
                menu.addItem(item)
            }

            if config.workspaces.isEmpty {
                let empty = NSMenuItem(title: "No Workspaces", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
        } catch {
            let failure = NSMenuItem(title: "Configuration Error", action: nil, keyEquivalent: "")
            failure.isEnabled = false
            menu.addItem(failure)
        }

        menu.addItem(.separator())
        if !lastSwitchIssues.isEmpty {
            for notice in lastSwitchIssues {
                let item = NSMenuItem(
                    title: switchIssueText(bundleId: notice.bundleId, issue: notice.issue),
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
            addItem("Review Window Set…", action: #selector(reviewWindowSet), to: menu)
            menu.addItem(.separator())
        }
        addItem("New Workspace…", action: #selector(newWorkspace), to: menu)
        addItem("Manage Workspaces…", action: #selector(manageWorkspaces), to: menu)
        addItem("Keyboard Shortcuts…", action: #selector(openKeyboardShortcuts), to: menu)
        menu.addItem(.separator())

        // Only reachable route to granting the permission everything else depends on,
        // so it stays in the menu while it is still missing.
        if !AXWindowManager.isTrusted {
            addItem("Allow Accessibility…", action: #selector(requestAccessibility), to: menu)
        }
        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        addItem("Check for Updates…", action: #selector(checkForUpdates), to: menu)
        addItem("Open Configuration…", action: #selector(openConfiguration), to: menu)
        menu.addItem(.separator())
        addItem("Quit EDN", action: #selector(quit), keyEquivalent: "q", to: menu)
    }

    private func addItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func installWorkspaceIndicator() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        workspaceIndicator.frame = button.bounds
        workspaceIndicator.autoresizingMask = [.width, .height]
        workspaceIndicator.setAccessibilityElement(false)
        button.addSubview(workspaceIndicator)
    }

    /// An accessory app never displays a menu bar, but its main menu still supplies the
    /// standard text-editing key equivalents the management window's fields need.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit EDN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }

    // MARK: - Actions

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performSwitch(to: name)
    }

    private func performSwitch(to name: String) {
        guard AXWindowManager.isTrusted else {
            logger.notice("Switch to \(name, privacy: .public) blocked: Accessibility permission missing")
            offerAccessibilitySetupIfNeeded(force: true)
            return
        }
        logger.debug("Switch requested: \(name, privacy: .public)")
        switchCoordinator.request(name)
    }

    private func performFocus(_ direction: FocusDirection, target: FocusTarget) {
        switchQueue.async { [weak self] in
            guard let self else { return }
            do {
                let controller = WorkspaceFocusController()
                let result = target == .app
                    ? try controller.focus(direction)
                    : try controller.focusWindow(direction)
                logger.debug("Focused \(result.target.rawValue, privacy: .public) for \(result.bundleId, privacy: .public) in \(result.workspace, privacy: .public)")
            } catch WorkspaceFocusError.noActiveWorkspace,
                    WorkspaceFocusError.noRunningApplications,
                    WorkspaceFocusError.noFocusableWindows {
                // Focus on an empty context is deliberately a quiet no-op.
                logger.debug("Focus \(direction.rawValue, privacy: .public) had no eligible app")
            } catch {
                logger.error("Focus \(direction.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func switchImmediately(to name: String) {
        do {
            let engine = WorkspaceEngine(config: try Config.load())
            let results = try engine.switchTo(name)
            for result in results where result.activation == .launched {
                launchesHandledBySwitch[result.bundleId] = Date()
            }
            DispatchQueue.main.async { [weak self] in
                self?.logger.debug("Switch completed: \(name, privacy: .public)")
                self?.lastSwitchIssues = results.compactMap { result in
                    result.issue.map { (name, result.bundleId, $0) }
                }
                self?.refreshStatusTitle()
                self?.manager?.reload()
            }
        } catch EngineError.notTrusted {
            DispatchQueue.main.async { [weak self] in
                self?.offerAccessibilitySetupIfNeeded(force: true)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.present(error: error)
            }
        }
    }

    @objc private func newWorkspace() {
        presentManager(beginningCreate: true)
    }

    @objc private func manageWorkspaces() {
        presentManager(beginningCreate: false)
    }

    @objc private func openKeyboardShortcuts() {
        let controller = focusSettings ?? FocusSettingsWindowController(host: self)
        focusSettings = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.present()
    }

    @objc private func reviewWindowSet() {
        presentManager(
            beginningCreate: false,
            selecting: lastSwitchIssues.first?.workspace
        )
    }

    private func presentManager(beginningCreate: Bool, selecting workspaceName: String? = nil) {
        let controller = manager ?? WorkspaceManagerWindowController(host: self)
        manager = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.present()
        if let workspaceName {
            controller.selectWorkspace(named: workspaceName)
        }
        if beginningCreate {
            controller.beginCreateFlow()
        }
    }

    @objc private func requestAccessibility() {
        offerAccessibilitySetupIfNeeded(force: true)
    }

    @objc private func openConfiguration() {
        do {
            if !FileManager.default.fileExists(atPath: Config.defaultPath.path) {
                try Config().save()
            }
            NSWorkspace.shared.open(Config.defaultPath)
        } catch {
            present(error: error)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            present(error: error)
        }
    }

    @objc private func checkForUpdates() {
        let fallback = "https://github.com/jacobalarcon/edn/releases/latest"
        let value = Bundle.main.object(forInfoDictionaryKey: "EDNReleaseURL") as? String
        guard let url = URL(string: value ?? fallback) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - WorkspaceManagerHost

    func managerSetHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        if suspended {
            // Releasing the manager unregisters every Carbon hotkey, so the chord being
            // recorded reaches the recorder instead of switching workspaces.
            hotkeys = nil
            configSignature = nil
        } else {
            reloadHotkeysIfNeeded(force: true)
        }
    }

    func managerDidMutateConfiguration() {
        reloadHotkeysIfNeeded(force: true)
        refreshStatusTitle()
    }

    func managerRequestsActivation(of workspaceName: String) {
        performSwitch(to: workspaceName)
    }

    func managerRequestsPresentation(
        of bundleIds: [String],
        in workspaceName: String,
        completion: @escaping ([String]) -> Void
    ) {
        switchQueue.async {
            guard (try? WorkspaceStateStore().read().activeWorkspace) == workspaceName else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let windowManager = SystemWindowManager()
            var seen: Set<String> = []
            let failures = bundleIds.compactMap { bundleId -> String? in
                guard seen.insert(bundleId).inserted else { return nil }
                let result = windowManager.activate(bundleID: bundleId, timeout: 5)
                return result.succeeded ? nil : bundleId
            }
            DispatchQueue.main.async { completion(failures) }
        }
    }

    func managerRequestsInstalledApplications(completion: @escaping ([InstalledApplication]) -> Void) {
        if let cachedInstalledApplications {
            completion(cachedInstalledApplications)
            return
        }
        discoveryQueue.async { [weak self] in
            let applications = SystemApplicationDiscovery().installedApplications()
            DispatchQueue.main.async {
                self?.cachedInstalledApplications = applications
                completion(applications)
            }
        }
    }

    // MARK: - FocusSettingsHost

    func focusSettingsSetHotkeysSuspended(_ suspended: Bool) {
        managerSetHotkeysSuspended(suspended)
    }

    func focusSettingsDidMutateConfiguration() {
        managerDidMutateConfiguration()
    }

    // MARK: - Support

    private func saveActiveWorkspaceForTerminationIfNeeded() {
        guard !didSaveOnTermination else { return }
        didSaveOnTermination = true
        do {
            let engine = WorkspaceEngine(config: try Config.load())
            _ = try engine.snapshotActiveWorkspaceForTermination()
        } catch {
            FileHandle.standardError.write("edn: warning: could not save active workspace on quit: \(error)\n".data(using: .utf8)!)
        }
    }

    private func reloadHotkeysIfNeeded(force: Bool = false) {
        guard !hotkeysSuspended else { return }
        guard let config = try? Config.load() else { return }
        let signature = ([
            config.general.hotkeyPrefix,
            config.general.focus.previousApp ?? "",
            config.general.focus.nextApp ?? "",
            config.general.focus.previousWindow ?? "",
            config.general.focus.nextWindow ?? ""
        ] + config.workspaces.map {
            "\($0.name):\($0.hotkey ?? "")"
        }).joined(separator: "|")
        guard force || signature != configSignature else { return }

        hotkeys = nil
        let manager = HotkeyManager { [weak self] action in
            switch action {
            case .workspace(let name): self?.performSwitch(to: name)
            case .focusPreviousApp: self?.performFocus(.previous, target: .app)
            case .focusNextApp: self?.performFocus(.next, target: .app)
            case .focusPreviousWindow: self?.performFocus(.previous, target: .window)
            case .focusNextWindow: self?.performFocus(.next, target: .window)
            }
        }
        for workspace in config.workspaces {
            guard let key = workspace.hotkey else { continue }
            manager.register(
                workspace: workspace.name,
                key: key,
                modifierNames: config.general.modifierNames
            )
        }
        if let raw = config.general.focus.previousApp,
           let chord = HotkeyChord(rawValue: raw) {
            manager.register(
                action: .focusPreviousApp,
                key: chord.key,
                modifierNames: chord.modifierNames
            )
        }
        if let raw = config.general.focus.nextApp,
           let chord = HotkeyChord(rawValue: raw) {
            manager.register(
                action: .focusNextApp,
                key: chord.key,
                modifierNames: chord.modifierNames
            )
        }
        if let raw = config.general.focus.previousWindow,
           let chord = HotkeyChord(rawValue: raw) {
            manager.register(
                action: .focusPreviousWindow,
                key: chord.key,
                modifierNames: chord.modifierNames
            )
        }
        if let raw = config.general.focus.nextWindow,
           let chord = HotkeyChord(rawValue: raw) {
            manager.register(
                action: .focusNextWindow,
                key: chord.key,
                modifierNames: chord.modifierNames
            )
        }
        hotkeys = manager
        configSignature = signature
    }

    private func refreshStatusTitle() {
        do {
            let config = try Config.load()
            let active = try WorkspaceStateStore().read().activeWorkspace
            let needsAccessibility = !AXWindowManager.isTrusted
            workspaceIndicator.update(
                workspaces: config.workspaces,
                activeWorkspace: active,
                hasWarning: needsAccessibility || !lastSwitchIssues.isEmpty
            )
            statusItem.length = workspaceIndicator.intrinsicContentSize.width
            let activeName = config.workspaces.first(where: { $0.name == active })?.name
            let warning: String
            if needsAccessibility {
                warning = " — Accessibility permission required"
            } else if !lastSwitchIssues.isEmpty {
                warning = " — layout needs attention"
            } else {
                warning = ""
            }
            statusItem.button?.toolTip = (activeName ?? "EDN Workspaces") + warning
            statusItem.button?.setAccessibilityLabel(
                activeName.map { "EDN workspaces, \($0) active\(warning)" } ?? "EDN workspaces"
            )
        } catch {
            workspaceIndicator.update(workspaces: [], activeWorkspace: nil, hasWarning: true)
            statusItem.length = workspaceIndicator.intrinsicContentSize.width
            statusItem.button?.toolTip = "EDN configuration error"
        }
    }

    private func offerAccessibilitySetupIfNeeded(force: Bool = false) {
        guard !AXWindowManager.isTrusted else {
            accessibilityDidBecomeTrusted()
            return
        }
        guard force || !didOfferAccessibilityThisLaunch else { return }
        didOfferAccessibilityThisLaunch = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow EDN to Arrange Windows"
        alert.informativeText = "EDN needs macOS Accessibility access to show, hide, move, and resize the apps in your workspaces. EDN does not monitor what you type."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            refreshStatusTitle()
            return
        }

        AXWindowManager.requestPermission()
        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard AXWindowManager.isTrusted else { return }
            timer.invalidate()
            self?.accessibilityPollTimer = nil
            self?.accessibilityDidBecomeTrusted()
        }
    }

    private func accessibilityDidBecomeTrusted() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        reloadHotkeysIfNeeded(force: true)
        refreshStatusTitle()
    }

    @objc private func workspaceSessionResumed(_ notification: Notification) {
        // Wake and unlock notifications can arrive back-to-back. Coalesce them, then
        // rebuild Carbon registrations after the user session is fully active.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resumeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.logger.info("Session resumed; refreshing global hotkeys")
                self.reloadHotkeysIfNeeded(force: true)
                self.refreshStatusTitle()
            }
            self.resumeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = application.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }

        switchQueue.async { [weak self] in
            guard let self else { return }
            if let handledAt = self.launchesHandledBySwitch.removeValue(forKey: bundleID),
               Date().timeIntervalSince(handledAt) < 5 {
                    self.logger.debug("Launch already handled by workspace switch: \(bundleID, privacy: .public)")
                    return
            }
            do {
                let engine = WorkspaceEngine(config: try Config.load())
                let results = try engine.restoreLaunchedApplication(bundleID: bundleID)
                guard !results.isEmpty else { return }
                self.logger.info("Restored launched app in active workspace: \(bundleID, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let active = try? WorkspaceStateStore().read().activeWorkspace else { return }
                    self.lastSwitchIssues = results.compactMap { result in
                        result.issue.map { (active, result.bundleId, $0) }
                    }
                    self.refreshStatusTitle()
                }
            } catch EngineError.notTrusted {
                DispatchQueue.main.async { [weak self] in
                    self?.offerAccessibilitySetupIfNeeded(force: true)
                }
            } catch {
                self.logger.error("Could not restore launched app \(bundleID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func switchIssueText(bundleId: String, issue: SwitchIssue) -> String {
        let name = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId })?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?
                .deletingPathExtension().lastPathComponent
            ?? bundleId
        switch issue {
        case .windowCountMismatch(let expected, let actual):
            return "\(name): expected \(expected) windows, found \(actual)"
        }
    }

    private func present(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "EDN Couldn’t Complete That"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
