import Foundation

public struct InstrumentationSnapshot: Equatable {
    public let counters: [String: Int]
}

public enum EDNInstrumentation {
    private static let lock = NSLock()
    private static var counters: [String: Int] = [:]
    // Environment is fixed for a process launch. Cache these once so the hot AX path
    // pays only a predictable branch when instrumentation is disabled.
    private static let tracingEnabled = ProcessInfo.processInfo.environment["EDN_TRACE"] == "1"
    private static let countingEnabled = tracingEnabled
        || ProcessInfo.processInfo.environment["EDN_COUNT_AX"] == "1"

    static var isTracing: Bool { tracingEnabled }

    public static func reset() {
        lock.lock()
        counters = [:]
        lock.unlock()
    }

    public static func snapshot() -> InstrumentationSnapshot {
        guard countingEnabled else { return InstrumentationSnapshot(counters: [:]) }
        lock.lock()
        defer { lock.unlock() }
        return InstrumentationSnapshot(counters: counters)
    }

    static func increment(_ name: String, by amount: Int = 1) {
        lock.lock()
        counters[name, default: 0] += amount
        lock.unlock()
    }

    static func axRead(_ attribute: String) {
        guard countingEnabled else { return }
        increment("ax.read")
        increment("ax.read.\(attribute)")
    }

    /// One batched `AXUIElementCopyMultipleAttributeValues` call: a single IPC round
    /// trip that returns several attributes. Counted as one `ax.read` (round trips are
    /// what cost time) while still crediting each attribute it carried.
    static func axReadBatch(_ attributes: [String]) {
        guard countingEnabled else { return }
        increment("ax.read")
        for attribute in attributes {
            increment("ax.read.\(attribute)")
        }
    }

    static func axWrite(_ attribute: String) {
        guard countingEnabled else { return }
        increment("ax.write")
        increment("ax.write.\(attribute)")
    }

    static func trace(_ message: String) {
        guard tracingEnabled else { return }
        FileHandle.standardError.write("edn trace: \(message)\n".data(using: .utf8)!)
    }

    static func measure<Result>(_ name: String, _ body: () throws -> Result) rethrows -> Result {
        guard tracingEnabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            let ms = Double(end - start) / 1_000_000
            trace("\(name) \(String(format: "%.2f", ms))ms")
        }
        return try body()
    }

    static func traceCounterDelta(since before: InstrumentationSnapshot, label: String) {
        guard tracingEnabled else { return }
        let after = snapshot().counters
        let reads = after["ax.read", default: 0] - before.counters["ax.read", default: 0]
        let writes = after["ax.write", default: 0] - before.counters["ax.write", default: 0]
        trace("\(label) ax.read=\(reads) ax.write=\(writes)")
    }
}
