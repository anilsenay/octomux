import Foundation

protocol LineStream: AnyObject {
    func writeLine(_ data: Data) -> Bool
    func readLine() -> Data?
    func close()
}

/// Line-oriented Unix socket.
final class LineSocket: LineStream {
    private let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { Darwin.close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private var closed = false
    deinit { close() }
    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func writeLine(_ data: Data) -> Bool {
        var d = data
        d.append(0x0A)
        return d.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    func readLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case unavailable
    case remote(String)
    var description: String {
        switch self {
        case .unavailable: return "Octomux daemon is not reachable"
        case .remote(let s): return s
        }
    }
}

/// Talks to the Octomux daemon. Requests go over one connection (serialized);
/// state/notification events arrive on a second, subscribed connection.
final class DaemonClient {
    private let queue = DispatchQueue(label: "octomux.daemon.requests")
    private var socket: LineStream?
    private var nextId: UInt64 = 1
    /// The daemon we talk to. Changing it (`switchHost`) reconnects everything.
    private(set) var host: Host = HostStore.current
    /// An extra-host client that was removed: its subscription loop exits.
    var stopped = false

    init() {}
    init(host: Host) { self.host = host }
    private var generation = 0
    private var subStream: LineStream?

    func openStream() -> LineStream? {
        if let argv = host.controlArgv { return ProcessLineStream(argv: argv) }
        if Self.isolated { return nil }
        return LineSocket(path: Paths.daemonSocket.path)
    }

    /// Unit tests without their own OCTOMUX_HOME: the default home is the user's, so no call reaches (or starts, or
    /// re-points the launchd agent of) the user's daemon. Settings the tests set stay in the test's model.
    /// An OCTOMUX_HOME in Application Support is the user's too: a terminal inside Octomux exports the real one, and
    /// `swift test` run there wrote the tests' layouts into the user's settings.
    static let isolated = NSClassFromString("XCTestCase") != nil && (!Paths.homeFromEnv || Paths.homeIsUsers)

    /// Points the client at another host; the subscription loop reconnects.
    func switchHost(_ h: Host) {
        queue.sync {
            socket?.close()
            socket = nil
        }
        host = h
        generation += 1
        subStream?.close()
    }

    var onState: ((DaemonState) -> Void)?
    /// An agent asked (over MCP) to start a planned task.
    var onTaskStart: (([String: Any]) -> Void)?
    var onNotify: ((AppNotification) -> Void)?
    var onNotificationsChanged: (() -> Void)?
    var onDisconnect: (() -> Void)?

    /// The user stopped Octomux (Settings): nothing may start the daemon again until they start it.
    static var held = false

    /// Whether this app process already made the launchd agent point at its own CLI.
    private static var agentChecked = false

    /// Makes sure a daemon is running (installs/kickstarts the launchd agent if needed).
    static func ensureDaemon() -> Bool {
        if isolated { return false }
        if held { return LineSocket(path: Paths.daemonSocket.path) != nil }
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plist = agents.appendingPathComponent("\(Paths.launchLabel).plist")
        if !Paths.homeFromEnv && !agentChecked {
            agentChecked = true
            if agentProgram(plist) != Paths.daemonBinary {
                // First run (or first run after the rename): also replaces the pre-rename `dev.ade-dev.daemon`
                // agent, whose daemon may be serving the socket right now. Also when the agent runs another
                // copy's CLI (the app was moved or updated to another place): the daemon and the agents' hooks
                // follow the agent's binary. Sessions survive the daemon restart. Only once, at launch: on a
                // reconnect, an older copy that is still open must not take the agent back.
                // The agent runs whichever binary installs it (its own path): the background app's.
                run([Paths.daemonBinary, "install-agent"])
            }
        }
        if LineSocket(path: Paths.daemonSocket.path) != nil { return true }
        run([Paths.cliBinary, "status"])
        // `octomux ctl hello` starts the daemon (launchd kickstart, or detached spawn).
        run([Paths.cliBinary, "ctl", "hello"])
        for _ in 0..<50 {
            if LineSocket(path: Paths.daemonSocket.path) != nil { return true }
            usleep(100_000)
        }
        return false
    }

    /// The binary the launchd agent starts (`ProgramArguments[0]`), nil without an agent.
    static func agentProgram(_ plist: URL) -> String? {
        guard let d = NSDictionary(contentsOf: plist), let args = d["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    @discardableResult
    static func run(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = ProcessInfo.processInfo.environment
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    func startSubscription() {
        Thread.detachNewThread { [weak self] in
            while true {
                guard let self, !self.stopped else { return }
                let gen = self.generation
                if let sock = self.openStream() {
                    self.subStream = sock
                    let req = try! JSONSerialization.data(withJSONObject: ["id": 0, "method": "subscribe", "params": [:]])
                    _ = sock.writeLine(req)
                    while let line = sock.readLine() {
                        if gen != self.generation { break }
                        self.handleEventLine(line)
                    }
                    sock.close()
                }
                if gen == self.generation {
                    DispatchQueue.main.async { self.onDisconnect?() }
                    // Local daemon gone (upgrade/crash): bring it back and resubscribe.
                    if !self.host.isRemote { _ = DaemonClient.ensureDaemon() }
                    Thread.sleep(forTimeInterval: self.host.isRemote ? 3 : 0.5)
                }
            }
        }
    }

    private func handleEventLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let event = obj["event"] as? String, let data = obj["data"] {
            guard let raw = try? JSONSerialization.data(withJSONObject: data) else { return }
            switch event {
            case "state":
                if let s = try? JSONDecoder().decode(DaemonState.self, from: raw) {
                    DispatchQueue.main.async { self.onState?(s) }
                }
            case "notify":
                if let n = try? JSONDecoder().decode(AppNotification.self, from: raw) {
                    DispatchQueue.main.async { self.onNotify?(n) }
                }
            case "notifications_changed":
                DispatchQueue.main.async { self.onNotificationsChanged?() }
            case "task.start_requested":
                if let d = data as? [String: Any] { DispatchQueue.main.async { self.onTaskStart?(d) } }
            default: break
            }
        } else if obj["id"] != nil, let result = obj["result"] {
            // Response to `subscribe` carries the initial state.
            if let raw = try? JSONSerialization.data(withJSONObject: result),
               let s = try? JSONDecoder().decode(DaemonState.self, from: raw) {
                DispatchQueue.main.async { self.onState?(s) }
            }
        }
    }

    /// Synchronous call (runs on the request queue; do not call from main for slow methods).
    func callSync(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        do {
            return try callOnce(method, params)
        } catch DaemonError.unavailable {
            // The daemon may have restarted: reconnect (starting it if needed) and retry once.
            if !host.isRemote, LineSocket(path: Paths.daemonSocket.path) == nil { _ = DaemonClient.ensureDaemon() }
            return try callOnce(method, params)
        }
    }

    private func callOnce(_ method: String, _ params: [String: Any]) throws -> Any {
        try queue.sync {
            if socket == nil { socket = openStream() }
            guard let sock = socket else { throw DaemonError.unavailable }
            let id = nextId
            nextId += 1
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            guard sock.writeLine(data) else { socket = nil; throw DaemonError.unavailable }
            while true {
                guard let line = sock.readLine() else { socket = nil; throw DaemonError.unavailable }
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if obj["event"] != nil { continue }
                if (obj["id"] as? NSNumber)?.uint64Value != id { continue }
                if let err = obj["error"] as? String { throw DaemonError.remote(err) }
                return obj["result"] ?? NSNull()
            }
        }
    }

    /// Async call; completion on main.
    func call(_ method: String, _ params: [String: Any] = [:], completion: ((Result<Any, Error>) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r: Result<Any, Error>
            do { r = .success(try self.callSync(method, params)) } catch { r = .failure(error) }
            DispatchQueue.main.async { completion?(r) }
        }
    }
}
