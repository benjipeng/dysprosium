import Foundation
import Darwin

public enum PreallocatedFileWriterError: LocalizedError, Sendable {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let reqStr = DysprosiumFormatters.bytes(required)
            let availStr = DysprosiumFormatters.bytes(available)
            return L("Not enough free storage space (requires \(reqStr), \(availStr) available).")
        }
    }
}

/// Thread-safe random-access file writer backed by a single POSIX file descriptor.
/// Uses `F_PREALLOCATE` contiguous reservation followed by lock-free `Darwin.pwrite`
/// so multiple concurrent byte-range workers write to distinct offsets simultaneously
/// with zero temporary part-file concatenation overhead.
public final class PreallocatedFileWriter: @unchecked Sendable {
    private static let minimumSafetyHeadroomBytes: Int64 = 16 * 1024 * 1024

    public let fileURL: URL
    private let fd: Int32
    private let closeLock = NSLock()
    private var isClosed = false

    public init(fileURL: URL, preallocateBytes: Int64?, truncateExisting: Bool) throws {
        self.fileURL = fileURL
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if let totalBytes = preallocateBytes, totalBytes > 0 {
            try Self.preflightDiskSpace(
                for: fileURL,
                parentDirectory: parent,
                targetBytes: totalBytes,
                truncateExisting: truncateExisting
            )
        }

        var openFlags = O_CREAT | O_RDWR | O_CLOEXEC
        if truncateExisting {
            openFlags |= O_TRUNC
        }

        let descriptor = fileURL.path.withCString { cPath in
            Darwin.open(cPath, openFlags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.fd = descriptor

        LiveContainerEnvironment.applySuspendLockedProtection(at: fileURL.path)

        if let totalBytes = preallocateBytes, totalBytes > 0 {
            var currentStat = stat()
            let existingSize: Int64 = fstat(descriptor, &currentStat) == 0 ? currentStat.st_size : 0
            if truncateExisting || existingSize != totalBytes {
                var store = fstore_t(
                    fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                    fst_posmode: F_PEOFPOSMODE,
                    fst_offset: 0,
                    fst_length: off_t(totalBytes),
                    fst_bytesalloc: 0
                )
                if fcntl(descriptor, F_PREALLOCATE, &store) == -1 {
                    store.fst_flags = UInt32(F_ALLOCATEALL)
                    _ = fcntl(descriptor, F_PREALLOCATE, &store)
                }
                if ftruncate(descriptor, off_t(totalBytes)) == -1 {
                    Darwin.close(descriptor)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOSPC)
                }
            }
        }
    }

    deinit {
        try? close()
    }

    /// Atomically writes `data` starting at `offset` without mutating the file descriptor's seek cursor.
    public func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var writtenSoFar = 0
            while remaining > 0 {
                let ptr = base.advanced(by: writtenSoFar)
                let rc = Darwin.pwrite(fd, ptr, remaining, off_t(offset) + off_t(writtenSoFar))
                if rc < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                writtenSoFar += rc
                remaining -= rc
            }
        }
    }

    public func synchronize() throws {
        closeLock.lock()
        let activeFD = isClosed ? -1 : fd
        closeLock.unlock()
        guard activeFD >= 0 else { return }
        if fsync(activeFD) == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func close() throws {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        let descriptor = fd
        closeLock.unlock()

        if Darwin.close(descriptor) == -1 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func preflightDiskSpace(
        for fileURL: URL,
        parentDirectory: URL,
        targetBytes: Int64,
        truncateExisting: Bool
    ) throws {
        var existingSize: Int64 = 0
        if !truncateExisting,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNumber = attrs[.size] as? NSNumber {
            existingSize = max(0, sizeNumber.int64Value)
        }
        let additionalNeeded = max(0, targetBytes - existingSize)
        guard additionalNeeded > 0 else { return }

        let availableBytes: Int64? = {
            if let values = try? parentDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]) {
                if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                    return important
                }
                if let standard = values.volumeAvailableCapacity, standard > 0 {
                    return Int64(standard)
                }
            }
            return LiveContainerEnvironment.availableDiskSpaceBytes
        }()

        if let available = availableBytes,
           available < additionalNeeded + minimumSafetyHeadroomBytes {
            throw PreallocatedFileWriterError.insufficientDiskSpace(
                requiredBytes: additionalNeeded,
                availableBytes: available
            )
        }
    }
}
