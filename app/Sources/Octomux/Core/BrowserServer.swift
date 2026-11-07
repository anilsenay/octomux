import Foundation

/// Listens on `$OCTOMUX_HOME/run/browser.sock` for browser tool calls from `octomux mcp` (one per agent session).
/// A request is one JSON line `{"tool", "args", "session"}`; the reply is one JSON line, an MCP `CallToolResult`.
/// The socket is private to the user (0600 in a 0700 folder), like the daemon's.
final class BrowserServer {
    static let shared = BrowserServer()
    private var fd: Int32 = -1

    static var socketURL: URL { Paths.home.appendingPathComponent("run/browser.sock") }

    func start() {
        guard fd < 0 else { return }
        let url = Self.socketURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = url.path
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); NSLog("browser socket path too long"); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(s, 16) == 0 else { close(s); NSLog("browser socket bind failed"); return }
        chmod(path, 0o600)
        fd = s
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(s, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        unlink(Self.socketURL.path)
    }

    private func serve(_ c: Int32) {
        let handle = FileHandle(fileDescriptor: c, closeOnDealloc: true)
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let reply = Self.process(line)
                handle.write(reply + Data([0x0A]))
            }
        }
    }

    /// Runs one call on the main actor and waits for its result (on this connection's thread).
    static func process(_ line: Data) -> Data {
        guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let tool = req["tool"] as? String else {
            return encode(["content": [["type": "text", "text": "Bad request."]], "isError": true])
        }
        let args = req["args"] as? [String: Any] ?? [:]
        let session = req["session"] as? String
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [String: Any] = [:]
        Task { @MainActor in
            result = await BrowserTools.run(tool: tool, args: args, session: session)
            sem.signal()
        }
        sem.wait()
        return encode(result)
    }

    private static func encode(_ v: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: v)) ?? Data(#"{"content":[{"type":"text","text":"Couldn't encode the result."}],"isError":true}"#.utf8)
    }
}
