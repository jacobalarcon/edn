import AppKit
import EDNCore

/// Compact, native menu-bar representation of EDN's configured workspaces.
/// Interaction remains on the containing NSStatusBarButton; this view only draws state.
final class WorkspaceIndicatorView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let horizontalInset: CGFloat = 5
    private let outerInset: CGFloat = 3
    private let gap: CGFloat = 2
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
        let labels = workspaces.isEmpty ? ["edn"] : workspaces.map { String($0.number) }
        let contentWidth = labels.reduce(CGFloat.zero) { partial, label in
            partial + labelWidth(label) + horizontalInset * 2
        }
        let gaps = CGFloat(max(labels.count - 1, 0)) * gap
        return NSSize(width: ceil(contentWidth + gaps + outerInset * 2), height: NSStatusBar.system.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let labels: [(name: String?, text: String)] = workspaces.isEmpty
            ? [(nil, "edn")]
            : workspaces.map { ($0.name, String($0.number)) }
        var x = outerInset

        for label in labels {
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

            let textColor: NSColor
            if isMenuHighlighted {
                textColor = .selectedMenuItemTextColor
            } else if isActive || workspaces.isEmpty {
                textColor = .labelColor
            } else {
                textColor = .secondaryLabelColor
            }
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
            x += cellWidth + gap
        }
    }

    private func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }
}
