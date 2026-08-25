import AppKit
import EDNCore

/// Resolves real application icons, cached per bundle id so scrolling a list never
/// re-reads bundles from disk.
final class ApplicationIconCache {
    private var icons: [String: NSImage] = [:]
    private let fallback = NSWorkspace.shared.icon(for: .applicationBundle)

    func icon(bundleId: String, bundleURL: URL?) -> NSImage {
        if let cached = icons[bundleId] { return cached }
        let url = bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? fallback
        icons[bundleId] = icon
        return icon
    }
}
