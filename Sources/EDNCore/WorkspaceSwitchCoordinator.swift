import Foundation

/// Serializes workspace switches without replaying stale keyboard input.
///
/// One switch may be in flight and at most one destination may be pending. Newer
/// requests replace that pending destination. If the newest request matches the
/// in-flight destination, pending work is cleared because the running switch already
/// represents the user's latest intent.
public final class WorkspaceSwitchCoordinator {
    public typealias Handler = (_ workspaceName: String) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let handler: Handler
    private var inFlight: String?
    private var pending: String?

    public init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    public func request(_ workspaceName: String) {
        lock.lock()
        if let inFlight {
            pending = workspaceName == inFlight ? nil : workspaceName
            lock.unlock()
            return
        }
        inFlight = workspaceName
        lock.unlock()

        queue.async { [weak self] in
            self?.drain(startingWith: workspaceName)
        }
    }

    private func drain(startingWith firstWorkspace: String) {
        var workspace = firstWorkspace
        while true {
            handler(workspace)

            lock.lock()
            guard let next = pending else {
                inFlight = nil
                lock.unlock()
                return
            }
            pending = nil
            inFlight = next
            workspace = next
            lock.unlock()
        }
    }
}
