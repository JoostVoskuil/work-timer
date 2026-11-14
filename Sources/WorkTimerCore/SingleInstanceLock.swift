import Darwin
import Foundation

public enum SingleInstanceError: Error {
    case alreadyRunning
}

/// Held for the process lifetime; the kernel releases it even after a crash.
public final class SingleInstanceLock {
    private let descriptor: Int32

    public init(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw SingleInstanceError.alreadyRunning }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        self.descriptor = descriptor
    }

    deinit {
        // Do not unlink the file: another process must always lock the same inode.
        Darwin.close(descriptor)
    }
}
