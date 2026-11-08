import Foundation

/// One JSON line in, one line out, over a connected socket (the browser tools' and the debug socket). Plain read and
/// write: FileHandle's `availableData` and `write(_:)` raise an Objective-C exception when the other side has gone
/// (a reply written after an agent's tool call was cancelled took the whole app down), and Swift can't catch those.
enum SocketLines {
    /// Reads lines from `fd` and writes each one's reply, until the other side closes or an error; then closes `fd`.
    static func serve(_ fd: Int32, reply: (Data) -> Data) {
        defer { close(fd) }
        guard noSigPipe(fd) else { return }   // the caller is gone already: nothing to answer
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard writeAll(fd, reply(line) + Data([0x0A])) else { return }
            }
        }
    }

    /// A write after the other side has gone fails with EPIPE instead of killing the app with SIGPIPE. Set while the
    /// connection is up: once the peer has closed, macOS refuses the option (EINVAL).
    @discardableResult
    static func noSigPipe(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Writes all of `data` to a socket that has `noSigPipe`; false when the other side has gone (or another error).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                p += n
                left -= n
            }
            return true
        }
    }
}
