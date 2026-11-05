// A blocking Unix-domain stream socket, and the line framing of NDJSON. A
// line can arrive split over many reads (a long `snapshot`), so bytes are
// buffered until a newline (docs/tasks/M1.md, "Notes carried over from
// shiibar-cc", and docs/tasks/M3.md, "Socket client").

import Darwin
import Foundation

/// Collects bytes and hands out complete lines without their newline.
public struct LineBuffer {
    private var pending = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

public enum SocketError: Error, Equatable {
    case pathTooLong
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case timedOut
    case closed
}

/// One connected socket. `close()` may be called from another thread to
/// end a blocking read.
public final class UnixSocket: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var buffer = LineBuffer()
    private var lines: [Data] = []

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connect to `path`. `timeout` bounds every later read; nil waits
    /// without a limit.
    public static func connect(path: String, timeout: TimeInterval?) throws -> UnixSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.connectFailed(errno) }
        var on: Int32 = 1
        // A write to a closed peer returns EPIPE instead of killing the app.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw SocketError.connectFailed(error)
        }
        return UnixSocket(fd: fd)
    }

    public func write(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.writeFailed(errno)
                }
                offset += written
            }
        }
    }

    /// The next complete line, or nil at the end of the stream.
    public func readLine() throws -> Data? {
        while lines.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 {
                return nil
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
                if closed { return nil }
                throw SocketError.readFailed(errno)
            }
            lines.append(contentsOf: buffer.feed(Data(chunk[0..<count])))
        }
        return lines.removeFirst()
    }

    private var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// Ends the connection; a read blocked in another thread returns. The
    /// descriptor itself is released in `deinit`, so a reader never touches
    /// a number the system has handed out again.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}
