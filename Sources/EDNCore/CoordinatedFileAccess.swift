import Darwin
import Foundation

/// Coordinates file transactions both between threads in this process and between
/// separate EDN processes. POSIX record locks are process-owned, so both layers matter.
enum CoordinatedFileAccess {
    private static let processLock = NSLock()

    static func read<Result>(lockURL: URL, _ body: () throws -> Result) throws -> Result {
        try withLock(lockURL: lockURL, type: Int16(F_RDLCK), body)
    }

    static func write<Result>(lockURL: URL, _ body: () throws -> Result) throws -> Result {
        try withLock(lockURL: lockURL, type: Int16(F_WRLCK), body)
    }

    private static func withLock<Result>(
        lockURL: URL,
        type: Int16,
        _ body: () throws -> Result
    ) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }

        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }

        var lock = Darwin.flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0

        while Darwin.fcntl(descriptor, F_SETLKW, &lock) == -1 {
            guard errno == EINTR else { throw currentPOSIXError() }
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }

        return try body()
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
