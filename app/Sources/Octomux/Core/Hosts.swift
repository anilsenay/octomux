import AppKit
import Foundation

/// Where a daemon runs. `local` = this Mac (Unix socket). `ssh` = `ssh <target> <cli> stdio`
/// for control and `ssh -t <target> <cli> attach <id>` for panes. `command` = any shell prefix
/// that reaches the other side (e.g. `env OCTOMUX_HOME=/tmp/x` to simulate a remote, or a custom ssh).
struct Host: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String          // "local" | "ssh" | "command"
    var target: String = ""   // ssh destination, e.g. "me@devbox"
    var cli: String = "octomux"   // path of the `octomux` CLI on that host
    var prefix: String = ""   // for kind == "command"
    var attachPrefix: String? // command kind: prefix for panes if it needs a TTY flag (e.g. `docker exec -it …`)
    var sshOptions: String?   // ssh kind: extra options, e.g. `-i ~/.ssh/devbox -p 2222`

    static let local = Host(id: "local", name: "This Mac", kind: "local")

    init(id: String, name: String, kind: String, target: String = "", cli: String = "octomux", prefix: String = "",
         attachPrefix: String? = nil, sshOptions: String? = nil) {
        (self.id, self.name, self.kind, self.target, self.cli, self.prefix, self.attachPrefix, self.sshOptions) =
            (id, name, kind, target, cli, prefix, attachPrefix, sshOptions)
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, target, cli, prefix, attachPrefix, sshOptions }
    /// Pre-rename saves call the CLI path `ade`.
    private enum LegacyKeys: String, CodingKey { case ade }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        cli = try c.decodeIfPresent(String.self, forKey: .cli) ?? legacy.decodeIfPresent(String.self, forKey: .ade) ?? "octomux"
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        attachPrefix = try c.decodeIfPresent(String.self, forKey: .attachPrefix)
        sshOptions = try c.decodeIfPresent(String.self, forKey: .sshOptions)
    }
    var isRemote: Bool { kind != "local" }

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ConnectTimeout=8"]
    private var extraSSH: [String] {
        (sshOptions ?? "").split(separator: " ").map { NSString(string: String($0)).expandingTildeInPath }
    }

    /// One shared ssh connection per host: the control link, panes, git and file reads all ride on it,
    /// so they open fast and authenticate once. The socket lives in a private /tmp folder (short path;
    /// ~/.ssh is left alone). Skipped when the user's own options already set multiplexing.
    static let muxDir = "/tmp/octomux-ssh-\(getuid())"
    var muxOpts: [String] {
        let own = (sshOptions ?? "").lowercased()
        if own.contains("controlmaster") || own.contains("controlpath") { return [] }
        try? FileManager.default.createDirectory(atPath: Self.muxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ["-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.muxDir)/%C", "-o", "ControlPersist=600"]
    }

    /// argv that yields a byte pipe to this host's daemon (nil = local socket).
    var controlArgv: [String]? {
        switch kind {
        case "ssh": return ["/usr/bin/ssh"] + Self.sshOpts + extraSSH + muxOpts + [target, cli, "stdio"]
        case "command": return ["/bin/sh", "-c", "\(prefix) \(cli.shellQuoted) stdio"]
        default: return nil
        }
    }

    /// Shell command a terminal pane runs to attach to `session`. Remote commands go through
    /// `/bin/sh -c` because the pane starts its command as a login program (argv0 "-name"),
    /// which some tools (docker) reject.
    func attachCommand(_ session: String) -> String {
        switch kind {
        case "ssh":
            let cmd = (["/usr/bin/ssh", "-t"] + Self.sshOpts + extraSSH + muxOpts + [target, cli, "attach", session]).map(\.shellQuoted).joined(separator: " ")
            return "/bin/sh -c " + cmd.shellQuoted
        case "command":
            let pre = (attachPrefix?.isEmpty == false) ? attachPrefix! : prefix
            return "/bin/sh -c " + "exec \(pre) \(cli.shellQuoted) attach \(session)".shellQuoted
        default: return "\(Paths.cliBinary.shellQuoted) attach \(session)"
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
            guard let d = UserDefaults.standard.data(forKey: "octomux.hosts"), let h = try? JSONDecoder().decode([Host].self, from: d) else { return [] }
            // Saved before the rename (`"ade"` key): write it back once with the current keys.
            if String(decoding: d, as: UTF8.self).contains(#""ade":"#) { all = h }
            return h
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "octomux.hosts") }
    }
    static var withLocal: [Host] { [.local] + all }
    static var currentId: String {
        get { UserDefaults.standard.string(forKey: "octomux.host") ?? "local" }
        set { UserDefaults.standard.set(newValue, forKey: "octomux.host") }
    }
    static var current: Host { withLocal.first { $0.id == currentId } ?? .local }
    /// Workspace (of this window) each extra host's project is assigned to (D14).
    static var projectWorkspace: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "octomux.projectWorkspace") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "octomux.projectWorkspace") }
    }
    /// Hosts shown alongside the current one (features.multi_host).
    static var attached: [String] {
        get { UserDefaults.standard.stringArray(forKey: "octomux.attachedHosts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "octomux.attachedHosts") }
    }
}

/// Line stream over a child process's stdin/stdout (ssh … octomux stdio).
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
