import Dispatch
import Foundation
import Testing
@testable import EDNCore

@Suite("Workspace switch coordination")
struct WorkspaceSwitchCoordinatorTests {
    @Test("Rapid input keeps only the latest pending destination")
    func latestPendingDestinationWins() {
        let queue = DispatchQueue(label: "edn-test-switch")
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let handled = LockedNames()

        let coordinator = WorkspaceSwitchCoordinator(queue: queue) { name in
            handled.append(name)
            if name == "one" {
                firstStarted.signal()
                releaseFirst.wait()
            }
        }

        coordinator.request("one")
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)
        coordinator.request("five")
        coordinator.request("two")
        coordinator.request("five")
        releaseFirst.signal()
        queue.async { drained.signal() }

        #expect(drained.wait(timeout: .now() + 1) == .success)
        #expect(handled.value == ["one", "five"])
    }

    @Test("Returning to the in-flight destination cancels pending work")
    func currentIntentCancelsPendingDestination() {
        let queue = DispatchQueue(label: "edn-test-switch-cancel")
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let handled = LockedNames()

        let coordinator = WorkspaceSwitchCoordinator(queue: queue) { name in
            handled.append(name)
            firstStarted.signal()
            releaseFirst.wait()
        }

        coordinator.request("one")
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)
        coordinator.request("five")
        coordinator.request("one")
        releaseFirst.signal()
        queue.async { drained.signal() }

        #expect(drained.wait(timeout: .now() + 1) == .success)
        #expect(handled.value == ["one"])
    }
}

private final class LockedNames {
    private let lock = NSLock()
    private var names: [String] = []

    func append(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}
