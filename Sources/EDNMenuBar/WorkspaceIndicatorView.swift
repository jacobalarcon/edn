import AppKit
import EDNCore

/// Compact, native menu-bar representation of EDN's configured workspaces.
/// Interaction remains on the containing NSStatusBarButton; this view only draws state.
final class WorkspaceIndicatorView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let horizontalInset: CGFloat = 5
    private let outerInset: CGFloat = 3
    private let boxHeight: CGFloat = 18

    private(set) var workspaces: [WorkspaceConfig] = []
    private(set) var activeWorkspace: String?
    private(set) var hasWarning = false
    var isMenuHighlighted = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let the status-bar button retain standard click/menu behavior.
        nil
    }

    func update(workspaces: [WorkspaceConfig], activeWorkspace: String?, hasWarning: Bool) {
        self.workspaces = workspaces.sorted { $0.number < $1.number }
        self.activeWorkspace = activeWorkspace
        self.hasWarning = hasWarning
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let label = activeLabel.text
        let contentWidth = labelWidth(label) + horizontalInset * 2
        return NSSize(width: ceil(contentWidth + outerInset * 2), height: NSStatusBar.system.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let label = activeLabel
        let x = outerInset
        let textWidth = labelWidth(label.text)
        let cellWidth = textWidth + horizontalInset * 2
        let cellRect = NSRect(
            x: x,
            y: floor((bounds.height - boxHeight) / 2),
            width: cellWidth,
            height: boxHeight
        )
        let isActive = label.name == activeWorkspace

        if isActive {
            let color: NSColor = hasWarning ? .systemOrange : .controlAccentColor
            let path = NSBezierPath(roundedRect: cellRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            color.withAlphaComponent(isMenuHighlighted ? 0.30 : 0.15).setFill()
            path.fill()
            color.withAlphaComponent(isMenuHighlighted ? 0.95 : 0.72).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let textColor: NSColor = isMenuHighlighted ? .selectedMenuItemTextColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let size = (label.text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: floor(cellRect.midX - size.width / 2),
            y: floor(cellRect.midY - size.height / 2)
        )
        (label.text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    private var activeLabel: (name: String?, text: String) {
        guard let activeWorkspace,
              let workspace = workspaces.first(where: { $0.name == activeWorkspace }) else {
            return (nil, "edn")
        }
        return (workspace.name, String(workspace.number))
    }
}
