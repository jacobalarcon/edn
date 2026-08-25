import AppKit
import CoreGraphics
import Foundation

public struct LiveDisplay: Codable, Equatable {
    public let id: UInt32
    public let name: String
    public let frame: Frame
    public let isMain: Bool
}

public struct LiveWindow: Codable, Equatable {
    public let title: String
    public let frame: Frame
    public let displayId: UInt32?
}

public struct LiveApplication: Codable, Equatable {
    public let name: String
    public let bundleId: String
    public let processId: Int32
    public let windows: [LiveWindow]
}

public struct LiveDesktopSnapshot: Codable, Equatable {
    public let displays: [LiveDisplay]
    public let applications: [LiveApplication]
}

public struct InstalledApplication: Equatable {
    public let name: String
    public let bundleId: String
    /// Location of the discovered .app bundle, retained so a UI can show the real
    /// application icon without re-resolving the bundle id through Launch Services.
    public let bundleURL: URL?

    public init(name: String, bundleId: String, bundleURL: URL? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.bundleURL = bundleURL
    }
}

public protocol ApplicationDiscovering {
    func installedApplications() -> [InstalledApplication]
}

/// Discovers application bundles from macOS' standard installation locations.
/// Membership discovery deliberately does not depend on an app currently running.
public struct SystemApplicationDiscovery: ApplicationDiscovering {
    public init() {}

    public func installedApplications() -> [InstalledApplication] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var byBundleId: [String: InstalledApplication] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                guard let bundleId = Bundle(url: url)?.bundleIdentifier, !bundleId.isEmpty else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                if byBundleId[bundleId] == nil {
                    byBundleId[bundleId] = InstalledApplication(name: name, bundleId: bundleId, bundleURL: url)
                }
            }
        }

        return byBundleId.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.bundleId < $1.bundleId : comparison == .orderedAscending
        }
    }
}

public protocol WorkspaceDiscovering {
    func visibleDesktop() throws -> LiveDesktopSnapshot
}

public struct SystemWorkspaceDiscovery: WorkspaceDiscovering {
    public init() {}

    public func visibleDesktop() throws -> LiveDesktopSnapshot {
        guard AXWindowManager.isTrusted else { throw EngineError.notTrusted }

        let displays = Self.displays()
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> LiveApplication? in
            guard !app.isTerminated,
                  !app.isHidden,
                  app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier else {
                return nil
            }

            let windows = AXWindowManager.windows(forPID: app.processIdentifier).compactMap { window -> LiveWindow? in
                guard window.subrole == (kAXStandardWindowSubrole as String),
                      !window.isMinimized,
                      let frame = window.frame,
                      frame.w > 0,
                      frame.h > 0 else {
                    return nil
                }
                return LiveWindow(
                    title: window.title,
                    frame: frame,
                    displayId: Self.bestDisplay(for: frame, displays: displays)?.id
                )
            }
            guard !windows.isEmpty else { return nil }

            return LiveApplication(
                name: app.localizedName ?? bundleId,
                bundleId: bundleId,
                processId: app.processIdentifier,
                windows: windows
            )
        }
        .sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.bundleId < $1.bundleId
        }

        return LiveDesktopSnapshot(displays: displays, applications: applications)
    }

    private static func displays() -> [LiveDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            return LiveDisplay(
                id: id,
                name: screen.localizedName,
                frame: Frame(x: bounds.origin.x, y: bounds.origin.y, w: bounds.width, h: bounds.height),
                isMain: id == CGMainDisplayID()
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.id < rhs.id
        }
    }

    private static func bestDisplay(for window: Frame, displays: [LiveDisplay]) -> LiveDisplay? {
        displays.max { overlapArea(window, $0.frame) < overlapArea(window, $1.frame) }
    }

    private static func overlapArea(_ lhs: Frame, _ rhs: Frame) -> Double {
        let width = max(0, min(lhs.x + lhs.w, rhs.x + rhs.w) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.h, rhs.y + rhs.h) - max(lhs.y, rhs.y))
        return width * height
    }
}
