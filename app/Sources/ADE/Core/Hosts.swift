import AppKit
import Foundation

/// Where a daemon runs. `local` = this Mac (Unix socket). `ssh` = `ssh <target> <ade> stdio`
/// for control and `ssh -t <target> <ade> attach <id>` for panes. `command` = any shell prefix
/// that reaches the other side (e.g. `env ADE_HOME=/tmp/x` to simulate a remote, or a custom ssh).
struct Host: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String          // "local" | "ssh" | "command"
    var target: String = ""   // ssh destination, e.g. "me@devbox"
    var ade: String = "ade"   // path of `ade` on that host
    var prefix: String = ""   // for kind == "command"
    var attachPrefix: String? // command kind: prefix for panes if it needs a TTY flag (e.g. `docker exec -it …`)
    var sshOptions: String?   // ssh kind: extra options, e.g. `-i ~/.ssh/devbox -p 2222`

    static let local = Host(id: "local", name: "This Mac", kind: "local")
    var isRemote: Bool { kind != "local" }

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ConnectTimeout=8"]
    private var extraSSH: [String] {
        (sshOptions ?? "").split(separator: " ").map { NSString(string: String($0)).expandingTildeInPath }
    }

    /// One shared ssh connection per host: the control link, panes, git and file reads all ride on it,
    /// so they open fast and authenticate once. The socket lives in a private /tmp folder (short path;
    /// ~/.ssh is left alone). Skipped when the user's own options already set multiplexing.
    static let muxDir = "/tmp/ade-ssh-\(getuid())"
    var muxOpts: [String] {
        let own = (sshOptions ?? "").lowercased()
        if own.contains("controlmaster") || own.contains("controlpath") { return [] }
        try? FileManager.default.createDirectory(atPath: Self.muxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.muxDir)/%C", "-o", "ControlPersist=600"]
    }

    /// argv that yields a byte pipe to this host's daemon (nil = local socket).
    var controlArgv: [String]? {
        switch kind {
        case "ssh": return ["/usr/bin/ssh"] + Self.sshOpts + extraSSH + muxOpts + [target, ade, "stdio"]
        case "command": return ["/bin/sh", "-c", "\(prefix) \(ade.shellQuoted) stdio"]
        default: return nil
        }
    }

    /// Shell command a terminal pane runs to attach to `session`. Remote commands go through
    /// `/bin/sh -c` because the pane starts its command as a login program (argv0 "-name"),
    /// which some tools (docker) reject.
    func attachCommand(_ session: String) -> String {
        switch kind {
        case "ssh":
            let cmd = (["/usr/bin/ssh", "-t"] + Self.sshOpts + extraSSH + muxOpts + [target, ade, "attach", session]).map(\.shellQuoted).joined(separator: " ")
            return "/bin/sh -c " + cmd.shellQuoted
        case "command":
            let pre = (attachPrefix?.isEmpty == false) ? attachPrefix! : prefix
            return "/bin/sh -c " + "exec \(pre) \(ade.shellQuoted) attach \(session)".shellQuoted
        default: return "\(Paths.adeBinary.shellQuoted) attach \(session)"
        }
    }

    var subtitle: String {
        switch kind {
        case "ssh": return target
        case "command": return prefix
        default: return "local daemon"
        }
    }
}

enum HostStore {
    static var all: [Host] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "ade.hosts"), let h = try? JSONDecoder().decode([Host].self, from: d) else { return [] }
            return h
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "ade.hosts") }
    }
    static var withLocal: [Host] { [.local] + all }
    static var currentId: String {
        get { UserDefaults.standard.string(forKey: "ade.host") ?? "local" }
        set { UserDefaults.standard.set(newValue, forKey: "ade.host") }
    }
    static var current: Host { withLocal.first { $0.id == currentId } ?? .local }
    /// Workspace (of this window) each extra host's project is assigned to (D14).
    static var projectWorkspace: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "ade.projectWorkspace") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "ade.projectWorkspace") }
    }
    /// Hosts shown alongside the current one (features.multi_host).
    static var attached: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ade.attachedHosts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ade.attachedHosts") }
    }
}

/// Line stream over a child process's stdin/stdout (ssh … ade stdio).
final class ProcessLineStream: LineStream {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()

    init?(argv: [String]) {
        let inPipe = Pipe(), outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
    }

    deinit { close() }

    func close() {
        if process.isRunning { process.terminate() }
        try? input.close()
    }

    func writeLine(_ data: Data) -> Bool {
        var d = data
        d.append(0x0A)
        do { try input.write(contentsOf: d); return true } catch { return false }
    }

    func readLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let chunk = output.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
