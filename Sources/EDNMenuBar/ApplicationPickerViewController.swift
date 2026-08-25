import AppKit
import EDNCore

/// Searchable list of installed applications, presented as a sheet. Applications already
/// in the workspace are omitted rather than shown disabled, so the list only offers
/// choices that do something.
final class ApplicationPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let applications: [InstalledApplication]
    private let icons: ApplicationIconCache
    private let onAdd: ([String]) -> Void

    private var matches: [InstalledApplication]
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let addButton = NSButton()

    init(
        applications: [InstalledApplication],
        excluding excludedBundleIds: Set<String>,
        icons: ApplicationIconCache,
        onAdd: @escaping ([String]) -> Void
    ) {
        self.applications = applications.filter { !excludedBundleIds.contains($0.bundleId) }
        self.icons = icons
        self.onAdd = onAdd
        matches = self.applications
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))

        searchField.placeholderString = "Search Applications"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(search)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(add)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.isEnabled = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func search() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = query.isEmpty ? applications : applications.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        addButton.isEnabled = false
    }

    @objc private func add() {
        let selected = table.selectedRowIndexes.compactMap { matches.indices.contains($0) ? matches[$0].bundleId : nil }
        guard !selected.isEmpty else { return }
        onAdd(selected)
        dismiss(nil)
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let application = matches[row]
        return ApplicationRowView(
            icon: icons.icon(bundleId: application.bundleId, bundleURL: application.bundleURL),
            name: application.name,
            detail: application.bundleId
        )
    }
}

/// One application line: real icon, name, and bundle id for disambiguation.
final class ApplicationRowView: NSTableCellView {
    init(icon: NSImage, name: String, detail: String) {
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        textField = nameLabel
        imageView = iconView

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
