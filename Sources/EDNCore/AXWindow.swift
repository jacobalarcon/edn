import AppKit
import ApplicationServices

public struct Frame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
    var size: CGSize { CGSize(width: w, height: h) }

    init(point: CGPoint, size: CGSize) {
        self.x = point.x; self.y = point.y; self.w = size.width; self.h = size.height
    }
}

/// Result of attempting to apply a frame to a window: what we asked for vs.
/// what the window actually ended up at (some windows silently reject part of a request,
/// e.g. Calculator refusing to resize -- reading the frame back is the only way to know).
public struct FrameApplyResult {
    public let requested: Frame
    public let actual: Frame?
    public var positionMatched: Bool {
        guard let actual else { return false }
        return abs(actual.x - requested.x) < 1 && abs(actual.y - requested.y) < 1
    }
    public var sizeMatched: Bool {
        guard let actual else { return false }
        return abs(actual.w - requested.w) < 1 && abs(actual.h - requested.h) < 1
    }
    public var fullyMatched: Bool { positionMatched && sizeMatched }
}

extension Frame {
    func matches(_ other: Frame, tolerance: Double = 1) -> Bool {
        abs(x - other.x) < tolerance
            && abs(y - other.y) < tolerance
            && abs(w - other.w) < tolerance
            && abs(h - other.h) < tolerance
    }
}

public enum AppActivationResult: Equatable {
    case activated
    case launched
    case applicationNotFound
    case launchTimedOut
    case failed(String)

    public var succeeded: Bool {
        switch self {
        case .activated, .launched: return true
        case .applicationNotFound, .launchTimedOut, .failed: return false
        }
    }

    public var failureDescription: String? {
        switch self {
        case .activated, .launched: return nil
        case .applicationNotFound: return "application not found"
        case .launchTimedOut: return "application launch timed out"
        case .failed(let message): return message
        }
    }
}

public enum AppHideResult: Equatable {
    case hidden
    case alreadyHidden
    case notRunning
    case failed

    public var succeeded: Bool { self != .failed }
}

/// Thin wrapper around a single AXUIElement window.
public struct AXWindow {
    let element: AXUIElement
    public let title: String
    public let subrole: String
    public let frame: Frame?
    public let isMinimized: Bool

    /// Read live because the main window changes whenever focus changes; unlike frame
    /// metadata, caching this during enumeration would make the next keypress stale.
    public var isMain: Bool {
        Self.getBool(element, kAXMainAttribute) ?? false
    }

    /// Raises this exact live window without assigning it any persistent EDN identity.
    @discardableResult
    public func focus() -> Bool {
        EDNInstrumentation.axWrite(kAXRaiseAction)
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    /// Applies a frame and reports what actually stuck. Order matters: size is set
    /// before position, because macOS clamps a window's position to fit the screen --
    /// moving first (while still the old, larger size) can cause the position to be
    /// rejected or clamped. Some apps only honor a resize once they're at their final
    /// position, so the size is set a second time -- but only for the windows that
    /// actually need it. The read-back that reports what stuck doubles as the test for
    /// that, so the common case (size accepted immediately) now costs three round trips
    /// instead of five, and the stubborn case still costs exactly what it did before.
    @discardableResult
    public func setFrame(_ frame: Frame) -> FrameApplyResult {
        _ = Self.setSize(element, kAXSizeAttribute, frame.size)
        _ = Self.setPoint(element, kAXPositionAttribute, frame.point)
        let settled = FrameApplyResult(requested: frame, actual: Self.liveFrame(element))
        guard !settled.sizeMatched else { return settled }
        _ = Self.setSize(element, kAXSizeAttribute, frame.size)
        return FrameApplyResult(requested: frame, actual: Self.liveFrame(element))
    }

    @discardableResult
    public func setMinimized(_ minimized: Bool) -> Bool {
        EDNInstrumentation.axWrite(kAXMinimizedAttribute)
        let value = NSNumber(value: minimized)
        return AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            value
        ) == .success
    }

    /// Reads several attributes in a single IPC round trip. AX charges per round trip,
    /// not per attribute, so one call for five attributes costs roughly what one
    /// individual read costs -- and an app like Chrome answers in milliseconds, not
    /// microseconds. Unset or unsupported attributes come back as an AXValue wrapping
    /// an AXError rather than as a gap in the array; those are normalized to nil so
    /// callers see exactly what an individual read would have given them.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var raw: CFArray?
        EDNInstrumentation.axReadBatch(names)
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(),
            &raw
        )
        guard err == .success,
              let values = raw as? [CFTypeRef],
              values.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return values.map { value in
            guard CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetType(value as! AXValue) == .axError else { return value }
            return nil
        }
    }

    static func unwrapPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func unwrapSize(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func liveFrame(_ element: AXUIElement) -> Frame? {
        let values = attributes(element, [kAXPositionAttribute as String, kAXSizeAttribute as String])
        guard let pos = unwrapPoint(values[0]), let size = unwrapSize(values[1]) else { return nil }
        return Frame(point: pos, size: size)
    }

    static func getBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        EDNInstrumentation.axRead(attr)
        let error = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        guard error == .success, let value = ref as? Bool else { return nil }
        return value
    }

    static func setPoint(_ element: AXUIElement, _ attr: String, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        EDNInstrumentation.axWrite(attr)
        return AXUIElementSetAttributeValue(element, attr as CFString, v) == .success
    }

    static func setSize(_ element: AXUIElement, _ attr: String, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        EDNInstrumentation.axWrite(attr)
        return AXUIElementSetAttributeValue(element, attr as CFString, v) == .success
    }
}

public protocol ManagedWindow {
    var title: String { get }
    var subrole: String { get }
    var frame: Frame? { get }
    var isMinimized: Bool { get }
    var isMain: Bool { get }
    func setFrame(_ frame: Frame) -> FrameApplyResult
    func setMinimized(_ minimized: Bool) -> Bool
    func focus() -> Bool
}

extension AXWindow: ManagedWindow {}

public extension ManagedWindow {
    /// Layout-only test doubles and integrations do not need focus behavior.
    var isMain: Bool { false }
    func focus() -> Bool { false }
}

public protocol WindowManaging {
    var isTrusted: Bool { get }
    func beginSwitch()
    func windows(forBundleID bundleID: String) -> [any ManagedWindow]
    func waitForWindow(bundleID: String, timeout: TimeInterval) -> [any ManagedWindow]
    func hide(bundleID: String) -> AppHideResult
    func hide(bundleIDs: [String]) -> [String: AppHideResult]
    func activate(bundleID: String, timeout: TimeInterval) -> AppActivationResult
}

public extension WindowManaging {
    func beginSwitch() {}
    /// Default, non-batched fallback for conformers (e.g. test doubles) that don't
    /// implement batched hide-verification: hides each app one at a time, still
    /// sequentially, still single-threaded -- just without the shared poll deadline.
    func hide(bundleIDs: [String]) -> [String: AppHideResult] {
        Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, hide(bundleID: $0)) })
    }
}

public struct SystemWindowManager: WindowManaging {
    private let applications = RunningApplicationIndex()

    public init() {}

    public var isTrusted: Bool { AXWindowManager.isTrusted }
    public func beginSwitch() {
        applications.refresh()
    }
    public func windows(forBundleID bundleID: String) -> [any ManagedWindow] {
        AXWindowManager.windows(forBundleID: bundleID, applications: applications).map { $0 as any ManagedWindow }
    }
    public func waitForWindow(bundleID: String, timeout: TimeInterval) -> [any ManagedWindow] {
        AXWindowManager.waitForWindow(bundleID: bundleID, timeout: timeout, applications: applications).map { $0 as any ManagedWindow }
    }
    public func hide(bundleID: String) -> AppHideResult {
        AXWindowManager.hide(bundleID: bundleID, applications: applications)
    }
    public func hide(bundleIDs: [String]) -> [String: AppHideResult] {
        AXWindowManager.hide(bundleIDs: bundleIDs, applications: applications)
    }
    public func activate(bundleID: String, timeout: TimeInterval) -> AppActivationResult {
        AXWindowManager.activate(bundleID: bundleID, timeout: timeout, applications: applications)
    }
}

private final class RunningApplicationIndex {
    // A miss shortly after a refresh means the app genuinely isn't running -- re-enumerating
    // the whole process table again can't change that outcome, so skip the redundant
    // enumeration if the index is still this fresh.
    private static let missRefreshCooldown: TimeInterval = 0.25

    private let lock = NSLock()
    private var applicationsByBundleID: [String: NSRunningApplication] = [:]
    private var lastRefresh: Date = .distantPast

    init() {
        refresh()
    }

    func refresh() {
        let applications = NSWorkspace.shared.runningApplications.reduce(into: [String: NSRunningApplication]()) { result, app in
            guard let bundleIdentifier = app.bundleIdentifier else { return }
            // Preserve the engine's previous first-match behavior when more than one
            // process reports the same bundle identifier.
            if result[bundleIdentifier] == nil {
                result[bundleIdentifier] = app
            }
        }
        lock.lock()
        applicationsByBundleID = applications
        lastRefresh = Date()
        lock.unlock()
    }

    func application(bundleID: String) -> NSRunningApplication? {
        lock.lock()
        if let app = applicationsByBundleID[bundleID], !app.isTerminated {
            lock.unlock()
            return app
        }
        applicationsByBundleID[bundleID] = nil
        let sinceRefresh = Date().timeIntervalSince(lastRefresh)
        if sinceRefresh < Self.missRefreshCooldown {
            // Already refreshed moments ago; a miss now is a real miss, not staleness.
            lock.unlock()
            return nil
        }
        lock.unlock()

        refresh()
        lock.lock()
        defer { lock.unlock() }
        return applicationsByBundleID[bundleID]
    }

    func set(_ application: NSRunningApplication, bundleID: String) {
        lock.lock()
        applicationsByBundleID[bundleID] = application
        lock.unlock()
    }
}

private final class ApplicationLaunchResult {
    private let lock = NSLock()
    private var value: Result<NSRunningApplication, Error>?

    func set(application: NSRunningApplication?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let application {
            value = .success(application)
        } else {
            value = .failure(error ?? CocoaError(.executableNotLoadable))
        }
    }

    func get() -> Result<NSRunningApplication, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Access point for reading/manipulating windows of running apps via the Accessibility API.
public enum AXWindowManager {

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the system Accessibility permission dialog if not already trusted.
    public static func requestPermission() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// All windows belonging to a running app, by bundle identifier.
    public static func windows(forBundleID bundleID: String) -> [AXWindow] {
        windows(forBundleID: bundleID, applications: nil)
    }

    fileprivate static func windows(forBundleID bundleID: String, applications: RunningApplicationIndex?) -> [AXWindow] {
        // When an index is present, `beginSwitch()` already refreshed it once for this
        // switch; a miss there means the app genuinely isn't running, so no second,
        // redundant full-process-table enumeration is needed here. The plain
        // `NSWorkspace` enumeration is only for callers with no index at all.
        guard let app = applications?.application(bundleID: bundleID)
            ?? (applications == nil ? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) : nil) else {
            return []
        }
        return windows(forPID: app.processIdentifier)
    }

    public static func windows(forPID pid: pid_t) -> [AXWindow] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25) // don't let one hung app block the whole engine

        var windowsRef: CFTypeRef?
        EDNInstrumentation.axRead(kAXWindowsAttribute)
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let raw = windowsRef as? [AXUIElement] else { return [] }

        // Every attribute the engine materializes for a window, fetched in one round
        // trip per window rather than five. This is the hot path: it runs for each app
        // of the outgoing workspace (snapshot) and each app of the incoming one (replay).
        let wanted = [
            kAXTitleAttribute as String,
            kAXSubroleAttribute as String,
            kAXMinimizedAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String
        ]
        let wrapped = raw.map { win -> AXWindow in
            let values = AXWindow.attributes(win, wanted)
            let title = (values[0] as? String) ?? ""
            let subrole = (values[1] as? String) ?? ""
            let isMinimized = (values[2] as? Bool) ?? false
            let frame = AXWindow.unwrapPoint(values[3]).flatMap { point in
                AXWindow.unwrapSize(values[4]).map { Frame(point: point, size: $0) }
            }
            return AXWindow(element: win, title: title, subrole: subrole, frame: frame, isMinimized: isMinimized)
        }

        // AX returns windows in an OS-internal order that isn't guaranteed stable across
        // calls. Sort deterministically (title, then position) so "the first window" means
        // the same window every time we look, absent an explicit windowTitle match.
        return wrapped.sorted { a, b in
            if a.title != b.title { return a.title < b.title }
            let af = a.frame ?? Frame(x: 0, y: 0, w: 0, h: 0)
            let bf = b.frame ?? Frame(x: 0, y: 0, w: 0, h: 0)
            if af.x != bf.x { return af.x < bf.x }
            if af.y != bf.y { return af.y < bf.y }
            if af.w != bf.w { return af.w < bf.w }
            return af.h < bf.h
        }
    }

    /// Hides an app (removes it from view without quitting it).
    public static func hide(bundleID: String) -> AppHideResult {
        hide(bundleID: bundleID, applications: nil)
    }

    fileprivate static func hide(bundleID: String, applications: RunningApplicationIndex?) -> AppHideResult {
        hide(bundleIDs: [bundleID], applications: applications)[bundleID] ?? .notRunning
    }

    /// Hides every given app, still one at a time and single-threaded (never call
    /// `NSRunningApplication.hide()`/`activate()`/`unhide()` concurrently across apps --
    /// they all mutate the one shared "which app is frontmost" window-server state).
    /// What's batched is only the verification poll: apps whose `hide()` call returns
    /// false (e.g. Ghostty, which completes the hide moments later) are rechecked
    /// together against one shared 0.4s deadline, instead of each paying its own
    /// up-to-0.4s wait serially.
    fileprivate static func hide(bundleIDs: [String], applications: RunningApplicationIndex?) -> [String: AppHideResult] {
        var results: [String: AppHideResult] = [:]
        var pending: [(bundleID: String, app: NSRunningApplication)] = []

        for bundleID in bundleIDs {
            guard let app = applications?.application(bundleID: bundleID)
                ?? (applications == nil ? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) : nil) else {
                results[bundleID] = .notRunning
                continue
            }
            if app.isHidden || isApplicationHidden(processIdentifier: app.processIdentifier) {
                results[bundleID] = .alreadyHidden
                continue
            }

            // Some apps (notably Ghostty) return false from NSRunningApplication.hide()
            // even though the hide completes moments later. NSRunningApplication's
            // time-varying properties are run-loop cached, so verify the application-level
            // AXHidden value before reporting a failure.
            if app.hide() {
                results[bundleID] = .hidden
            } else {
                pending.append((bundleID, app))
            }
        }

        guard !pending.isEmpty else { return results }

        let deadline = Date().addingTimeInterval(0.4)
        var remaining = pending
        repeat {
            remaining.removeAll { entry in
                guard isApplicationHidden(processIdentifier: entry.app.processIdentifier) else { return false }
                results[entry.bundleID] = .hidden
                return true
            }
            if remaining.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline

        for entry in remaining {
            results[entry.bundleID] = .failed
        }
        return results
    }

    private static func isApplicationHidden(processIdentifier: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return AXWindow.getBool(element, kAXHiddenAttribute) ?? false
    }

    /// Activates an app, launching it first if it isn't running. Blocks (with a timeout)
    /// until the launch completes, since short-lived CLI processes would otherwise exit
    /// before NSWorkspace's async launch finishes.
    public static func activate(bundleID: String, timeout: TimeInterval = 5) -> AppActivationResult {
        activate(bundleID: bundleID, timeout: timeout, applications: nil)
    }

    fileprivate static func activate(bundleID: String, timeout: TimeInterval = 5, applications: RunningApplicationIndex?) -> AppActivationResult {
        if let app = applications?.application(bundleID: bundleID)
            ?? (applications == nil ? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) : nil) {
            let unhidden = app.unhide()
            let activated = app.activate()
            return (unhidden || activated || !app.isHidden)
                ? .activated
                : .failed("application refused activation")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .applicationNotFound
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let sema = DispatchSemaphore(value: 0)
        let launchResult = ApplicationLaunchResult()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { application, error in
            launchResult.set(application: application, error: error)
            sema.signal()
        }
        guard sema.wait(timeout: .now() + timeout) == .success else {
            return .launchTimedOut
        }
        switch launchResult.get() {
        case .success(let application):
            applications?.set(application, bundleID: bundleID)
            return .launched
        case .failure(let error): return .failed("application launch failed: \(error.localizedDescription)")
        case nil: return .failed("application launch completed without a result")
        }
    }

    /// Polls for at least one window to appear for the given bundle id, up to `timeout` seconds.
    /// Newly-launched apps take a moment before their first window is accessible via AX.
    public static func waitForWindow(bundleID: String, timeout: TimeInterval = 5) -> [AXWindow] {
        waitForWindow(bundleID: bundleID, timeout: timeout, applications: nil)
    }

    fileprivate static func waitForWindow(bundleID: String, timeout: TimeInterval = 5, applications: RunningApplicationIndex?) -> [AXWindow] {
        let deadline = Date().addingTimeInterval(timeout)
        var pollInterval: TimeInterval = 0.01
        while Date() < deadline {
            let windows = self.windows(forBundleID: bundleID, applications: applications)
            if !windows.isEmpty { return windows }
            // Newly launched apps often publish their first AX window quickly. Poll
            // eagerly at first, then back off to the previous 100ms cadence so a slow
            // launch does not spin needlessly for the full timeout.
            Thread.sleep(forTimeInterval: pollInterval)
            pollInterval = min(pollInterval * 2, 0.1)
        }
        return []
    }
}
