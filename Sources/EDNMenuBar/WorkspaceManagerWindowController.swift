import AppKit
import EDNCore

/// Everything the manager window needs from the running menu-bar app. Keeping these
/// behind a protocol means the window never touches the hotkey manager, the switch
/// queue, or the AX layer directly.
protocol WorkspaceManagerHost: AnyObject {
    /// Suspends global workspace hotkeys while a shortcut is being recorded, so ⌥2
    /// reaches the recorder instead of switching workspaces mid-edit.
    func managerSetHotkeysSuspended(_ suspended: Bool)
    /// Config or state was written; reload hotkeys and refresh the status item.
    func managerDidMutateConfiguration()
    /// Activates a workspace through the existing switch coordinator.
    func managerRequestsActivation(of workspaceName: String)
    /// Presents newly added apps only if this workspace is still active when the
    /// request reaches the serialized AppKit queue.
    func managerRequestsPresentation(
        of bundleIds: [String],
        in workspaceName: String,
        completion: @escaping ([String]) -> Void
    )
    func managerRequestsInstalledApplications(completion: @escaping ([InstalledApplication]) -> Void)
}

final class WorkspaceManagerWindowController: NSWindowController,
                                              NSWindowDelegate,
                                              NSTableViewDataSource,
                                              NSTableViewDelegate,
                                              NSTextFieldDelegate,
                                              ShortcutRecorderDelegate {
    weak var host: WorkspaceManagerHost?

    private var workspaces: [WorkspaceConfig] = []
    private var activeWorkspace: String?
    private var modifierNames: [String] = ["alt"]
    private var selectedWorkspaceName: String?
    private var installedApplications: [InstalledApplication] = []
    private var installedByBundleId: [String: InstalledApplication] = [:]
    private var isPopulating = false
    private let icons = ApplicationIconCache()

    private let workspaceTable = NSTableView()
    private let workspaceControls = NSSegmentedControl()
    private let detailStack = NSView()
    private let placeholderLabel = NSTextField(labelWithString: "No workspace selected.")
    private let nameField = NSTextField()
    private let recorder: ShortcutRecorder
    private let appTable = NSTableView()
    private let appControls = NSSegmentedControl()
    private let emptyStateLabel = NSTextField(
        labelWithString: "Add apps, arrange their windows, then switch away. EDN remembers."
    )

    init(host: WorkspaceManagerHost) {
        recorder = ShortcutRecorder(modifierNames: modifierNames)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workspaces"
        window.minSize = NSSize(width: 660, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("EDNWorkspaceManager")
        super.init(window: window)
        self.host = host
        window.delegate = self
        window.contentViewController = makeSplitViewController()
        loadInstalledApplications()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Presentation

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func selectWorkspace(named name: String) {
        guard workspaces.contains(where: { $0.name == name }) else { return }
        selectedWorkspaceName = name
        reloadSidebar()
        loadDetail()
    }

    /// The "+" flow, shared by the sidebar button and the New Workspace… menu item:
    /// create a blank workspace, select it, activate it, and leave the name selected
    /// so the first thing typed names it.
    func beginCreateFlow() {
        addWorkspace()
    }

    // MARK: - Layout

    private func makeSplitViewController() -> NSSplitViewController {
        let sidebar = NSViewController()
        sidebar.view = makeSidebarView()
        let detail = NSViewController()
        detail.view = makeDetailView()

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        return split
    }

    private func makeSidebarView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 460))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        workspaceTable.addTableColumn(column)
        workspaceTable.headerView = nil
        workspaceTable.style = .sourceList
        workspaceTable.rowHeight = 26
        workspaceTable.dataSource = self
        workspaceTable.delegate = self
        workspaceTable.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = workspaceTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        workspaceControls.segmentCount = 2
        workspaceControls.segmentStyle = .separated
        workspaceControls.trackingMode = .momentary
        workspaceControls.controlSize = .small
        workspaceControls.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        workspaceControls.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        workspaceControls.setWidth(28, forSegment: 0)
        workspaceControls.setWidth(28, forSegment: 1)
        workspaceControls.setToolTip("New workspace", forSegment: 0)
        workspaceControls.setToolTip("Delete workspace", forSegment: 1)
        workspaceControls.target = self
        workspaceControls.action = #selector(workspaceControlPressed)
        workspaceControls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(workspaceControls)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: workspaceControls.topAnchor, constant: -6),

            workspaceControls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            workspaceControls.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        return container
    }

    private func makeDetailView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholderLabel)

        detailStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailStack)

        nameField.placeholderString = "Workspace name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitMetadataEdits)

        recorder.recorderDelegate = self

        let grid = NSGridView(views: [
            [rightLabel("Name"), nameField],
            [rightLabel("Shortcut"), recorder]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addSubview(grid)

        let appsHeader = NSTextField(labelWithString: "Apps")
        appsHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        appsHeader.textColor = .secondaryLabelColor
        appsHeader.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addSubview(appsHeader)

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.resizingMask = .autoresizingMask
        appTable.addTableColumn(appColumn)
        appTable.headerView = nil
        appTable.rowHeight = 28
        appTable.allowsMultipleSelection = true
        appTable.dataSource = self
        appTable.delegate = self

        let appScroll = NSScrollView()
        appScroll.documentView = appTable
        appScroll.hasVerticalScroller = true
        appScroll.borderType = .bezelBorder
        appScroll.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addSubview(appScroll)

        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addSubview(emptyStateLabel)

        appControls.segmentCount = 2
        appControls.segmentStyle = .separated
        appControls.trackingMode = .momentary
        appControls.controlSize = .small
        appControls.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        appControls.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        appControls.setWidth(28, forSegment: 0)
        appControls.setWidth(28, forSegment: 1)
        appControls.setToolTip("Add applications", forSegment: 0)
        appControls.setToolTip("Remove selected applications", forSegment: 1)
        appControls.target = self
        appControls.action = #selector(appControlPressed)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.addView(appControls, in: .leading)
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            detailStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            detailStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            detailStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            detailStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            grid.topAnchor.constraint(equalTo: detailStack.topAnchor),
            grid.leadingAnchor.constraint(equalTo: detailStack.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: detailStack.trailingAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            recorder.widthAnchor.constraint(equalToConstant: 150),

            appsHeader.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            appsHeader.leadingAnchor.constraint(equalTo: detailStack.leadingAnchor),

            appScroll.topAnchor.constraint(equalTo: appsHeader.bottomAnchor, constant: 6),
            appScroll.leadingAnchor.constraint(equalTo: detailStack.leadingAnchor),
            appScroll.trailingAnchor.constraint(equalTo: detailStack.trailingAnchor),
            appScroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -8),

            emptyStateLabel.centerXAnchor.constraint(equalTo: appScroll.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: appScroll.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: appScroll.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: appScroll.trailingAnchor, constant: -16),

            bottomRow.leadingAnchor.constraint(equalTo: detailStack.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: detailStack.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: detailStack.bottomAnchor)
        ])

        return container
    }

    private func rightLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    // MARK: - Loading

    /// Re-reads config and state and repopulates the window. Safe to call at any time;
    /// an in-progress text edit is left alone so a background refresh cannot swallow
    /// what is currently being typed.
    func reload() {
        do {
            let config = try Config.load()
            workspaces = config.workspaces.sorted { $0.number < $1.number }
            modifierNames = config.general.modifierNames
            activeWorkspace = try WorkspaceStateStore().read().activeWorkspace
        } catch {
            workspaces = []
            activeWorkspace = nil
            report(error)
        }

        if let selected = selectedWorkspaceName, !workspaces.contains(where: { $0.name == selected }) {
            selectedWorkspaceName = nil
        }
        if selectedWorkspaceName == nil {
            selectedWorkspaceName = workspaces.first?.name
        }

        recorder.setModifierNames(modifierNames)
        reloadSidebar()
        loadDetail()
    }

    private func loadInstalledApplications() {
        appControls.setEnabled(false, forSegment: 0)
        host?.managerRequestsInstalledApplications { [weak self] applications in
            guard let self else { return }
            self.installedApplications = applications
            self.installedByBundleId = Dictionary(
                applications.map { ($0.bundleId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.appTable.reloadData()
            self.appControls.setEnabled(!applications.isEmpty, forSegment: 0)
        }
    }

    private func reloadSidebar() {
        isPopulating = true
        workspaceTable.reloadData()
        if let index = workspaces.firstIndex(where: { $0.name == selectedWorkspaceName }) {
            workspaceTable.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            workspaceTable.deselectAll(nil)
        }
        isPopulating = false
        workspaceControls.setEnabled(selectedWorkspaceName != nil, forSegment: 1)
    }

    private var selectedWorkspace: WorkspaceConfig? {
        workspaces.first { $0.name == selectedWorkspaceName }
    }

    private var isEditingTextField: Bool {
        guard let responder = window?.firstResponder as? NSTextView, responder.isFieldEditor else { return false }
        let delegate = responder.delegate as? NSView
        return delegate === nameField
    }

    private func loadDetail() {
        guard let workspace = selectedWorkspace else {
            detailStack.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = workspaces.isEmpty
                ? "Create your first workspace with +."
                : "No workspace selected."
            appTable.reloadData()
            return
        }
        detailStack.isHidden = false
        placeholderLabel.isHidden = true

        isPopulating = true
        if !isEditingTextField {
            nameField.stringValue = workspace.name
        }
        recorder.setShortcutKey(workspace.hotkey)
        appTable.reloadData()
        isPopulating = false

        emptyStateLabel.isHidden = !workspace.apps.isEmpty
        appControls.setEnabled(!appTable.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    // MARK: - Mutations

    /// Runs one authoring mutation, then re-reads everything from disk. On failure the
    /// on-screen fields are restored from config so the window never shows a value that
    /// was rejected.
    @discardableResult
    private func mutate(_ body: (WorkspaceAuthor) throws -> WorkspaceConfig?) -> Bool {
        do {
            if let workspace = try body(WorkspaceAuthor()) {
                selectedWorkspaceName = workspace.name
            }
            host?.managerDidMutateConfiguration()
            reload()
            return true
        } catch {
            window?.makeFirstResponder(nil)
            reload()
            report(error)
            return false
        }
    }

    @objc private func workspaceControlPressed(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: addWorkspace()
        case 1: confirmDeleteWorkspace()
        default: break
        }
    }

    private func addWorkspace() {
        var created: WorkspaceConfig?
        mutate { author in
            let workspace = try author.createBlank()
            created = workspace
            return workspace
        }
        guard let workspace = created, selectedWorkspaceName == workspace.name else { return }
        host?.managerRequestsActivation(of: workspace.name)
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    private func confirmDeleteWorkspace() {
        guard let workspace = selectedWorkspace, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(workspace.name)”?"
        alert.informativeText = "Its apps stay installed. EDN forgets this workspace's remembered window positions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.selectedWorkspaceName = nil
            self?.mutate { author in
                try author.delete(name: workspace.name)
                return nil
            }
        }
    }

    @objc private func commitMetadataEdits() {
        applyMetadataEdits()
    }

    private func applyMetadataEdits(hotkeyOverride: String?? = nil) {
        guard !isPopulating, let workspace = selectedWorkspace else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hotkey = hotkeyOverride ?? recorder.shortcutKey

        guard !name.isEmpty else {
            loadDetail()
            present(message: "A Name Is Required", detail: "Give the workspace a short, recognizable name.")
            return
        }
        guard name != workspace.name || hotkey != workspace.hotkey else { return }

        mutate { author in
            try author.updateMetadata(
                name: workspace.name,
                newName: name,
                hotkey: hotkey
            )
        }
    }

    @objc private func appControlPressed(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: presentApplicationPicker()
        case 1: removeSelectedApplications()
        default: break
        }
    }

    private func presentApplicationPicker() {
        guard let workspace = selectedWorkspace,
              let detailViewController = (window?.contentViewController as? NSSplitViewController)?
                  .splitViewItems.last?.viewController else { return }
        let picker = ApplicationPickerViewController(
            applications: installedApplications,
            excluding: Set(workspace.apps.map(\.bundleId)),
            icons: icons
        ) { [weak self] bundleIds in
            self?.addApplications(bundleIds, to: workspace)
        }
        detailViewController.presentAsSheet(picker)
    }

    private func addApplications(_ bundleIds: [String], to workspace: WorkspaceConfig) {
        guard !bundleIds.isEmpty else { return }
        let didAdd = mutate { author in
            try author.addApplications(
                workspace: workspace.name,
                bundleIds: Set(bundleIds),
                availableApplications: installedApplications
            )
        }
        guard didAdd else { return }
        host?.managerRequestsPresentation(
            of: bundleIds,
            in: workspace.name
        ) { [weak self] failures in
            guard let self, !failures.isEmpty else { return }
            let names = failures.map { self.installedByBundleId[$0]?.name ?? $0 }
            self.present(
                message: "Some Apps Couldn’t Open",
                detail: names.joined(separator: ", ")
            )
        }
    }

    private func removeSelectedApplications() {
        guard let workspace = selectedWorkspace else { return }
        let removed = Set(appTable.selectedRowIndexes.compactMap {
            workspace.apps.indices.contains($0) ? workspace.apps[$0].stateKey : nil
        })
        guard !removed.isEmpty else { return }
        mutate { author in
            try author.removeApplications(
                workspace: workspace.name,
                stateKeys: removed
            )
        }
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === workspaceTable ? workspaces.count : (selectedWorkspace?.apps.count ?? 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === workspaceTable {
            let workspace = workspaces[row]
            return WorkspaceRowView(
                number: workspace.number,
                name: workspace.name,
                isActive: workspace.name == activeWorkspace
            )
        }
        guard let app = selectedWorkspace?.apps[row] else { return nil }
        let installed = installedByBundleId[app.bundleId]
        return ApplicationRowView(
            icon: icons.icon(bundleId: app.bundleId, bundleURL: installed?.bundleURL),
            name: installed?.name ?? app.bundleId,
            detail: app.bundleId
        )
    }

    /// Selecting a workspace only loads it for editing. Activation stays an explicit
    /// act: a hotkey, the status menu, or creating a new workspace.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isPopulating else { return }
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === workspaceTable {
            let row = workspaceTable.selectedRow
            selectedWorkspaceName = workspaces.indices.contains(row) ? workspaces[row].name : nil
            workspaceControls.setEnabled(selectedWorkspaceName != nil, forSegment: 1)
            loadDetail()
        } else {
            appControls.setEnabled(!appTable.selectedRowIndexes.isEmpty, forSegment: 1)
        }
    }

    // MARK: - Delegates

    func controlTextDidEndEditing(_ notification: Notification) {
        applyMetadataEdits()
    }

    func shortcutRecorderDidBeginCapture(_ recorder: ShortcutRecorder) {
        host?.managerSetHotkeysSuspended(true)
    }

    func shortcutRecorderDidEndCapture(_ recorder: ShortcutRecorder) {
        host?.managerSetHotkeysSuspended(false)
    }

    func shortcutRecorder(_ recorder: ShortcutRecorder, didRecord key: String?) {
        applyMetadataEdits(hotkeyOverride: .some(key))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Ends shortcut capture (and its hotkey suspension) when focus leaves the window.
        window?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        host?.managerSetHotkeysSuspended(false)
    }

    // MARK: - Errors

    private func report(_ error: Error) {
        present(message: "EDN Couldn’t Complete That", detail: String(describing: error))
    }

    private func present(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// One sidebar line: active indicator, workspace number, workspace name.
final class WorkspaceRowView: NSTableCellView {
    init(number: Int, name: String, isActive: Bool) {
        super.init(frame: .zero)

        let indicator = NSImageView()
        indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Active workspace")
        indicator.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        indicator.contentTintColor = .controlAccentColor
        indicator.isHidden = !isActive
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        let numberLabel = NSTextField(labelWithString: "\(number)")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numberLabel)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        textField = nameLabel

        setAccessibilityLabel(isActive ? "\(name), active" : name)

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 10),

            numberLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 4),
            numberLabel.widthAnchor.constraint(equalToConstant: 18),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
