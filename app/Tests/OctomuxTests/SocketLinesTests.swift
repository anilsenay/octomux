import XCTest
@testable import Octomux

/// A reply written to a connection whose other side has gone ends that connection; the app goes on (it used to raise
/// an uncaught Objective-C exception and quit).
final class SocketLinesTests: XCTestCase {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], fds[1])
    }

    func testRepliesLineByLine() {
        let (server, client) = pair()
        SocketLines.noSigPipe(client)
        let done = expectation(description: "served")
        Thread.detachNewThread { SocketLines.serve(server) { Data("re:".utf8) + $0 }; done.fulfill() }
        XCTAssertTrue(SocketLines.writeAll(client, Data("a\nb\n".utf8)))
        var got = Data()
        var buf = [UInt8](repeating: 0, count: 64)
        while got.filter({ $0 == 0x0A }).count < 2 {
            let n = buf.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "re:a\nre:b\n")
        close(client)
        wait(for: [done], timeout: 2)
    }

    /// The caller asks and leaves before the reply: the write fails quietly and serve returns.
    func testCallerGoneBeforeTheReply() {
        let (server, client) = pair()
        SocketLines.noSigPipe(client)
        let done = expectation(description: "served")
        let asked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            SocketLines.serve(server) { _ in
                asked.signal()
                Thread.sleep(forTimeInterval: 0.2)          // the caller closes meanwhile
                return Data(repeating: 0x41, count: 512 * 1024)
            }
            done.fulfill()
        }
        _ = SocketLines.writeAll(client, Data("x\n".utf8))
        asked.wait()
        close(client)
        wait(for: [done], timeout: 3)
    }

    func testWriteToAClosedPeerIsFalse() {
        let (a, b) = pair()
        SocketLines.noSigPipe(a)                     // as the servers do when they accept a connection
        close(b)
        XCTAssertFalse(SocketLines.writeAll(a, Data(repeating: 1, count: 256 * 1024)))   // no SIGPIPE, no exception
        close(a)
    }

    /// The caller left before the connection was served: nothing is written (no SIGPIPE).
    func testCallerGoneBeforeServing() {
        let (server, client) = pair()
        _ = SocketLines.writeAll(client, Data("x\n".utf8))
        close(client)
        var answered = false
        SocketLines.serve(server) { _ in answered = true; return Data("y".utf8) }
        _ = answered   // read or not, serve returns and the process lives
    }
}
