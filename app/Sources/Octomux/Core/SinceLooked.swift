import Foundation

/// "Since you looked": what an agent changed after you last looked at it. Looking (opening its pane, or its
/// changes) keeps a snapshot of its checkout as a git tree (uncommitted and untracked files too, through a copy of
/// the index, so the real index is never touched); later the snapshot is compared with the checkout as it is.
final class SinceLooked: ObservableObject {
    static let shared = SinceLooked()
    static let key = "octomux.sinceLooked"          // session id → [tree, unix seconds, work path]

    /// Session id → files changed since you looked (only for sessions someone asked about).
    @Published private(set) var changed: [String: [String]] = [:]
    private var marks: [String: [String]]
    private var asked: [String: Date] = [:]
    private let queue = DispatchQueue(label: "octomux.since", qos: .utility)
    let defaults: UserDefaults
    /// Takes a snapshot of a checkout (tests and the fixture swap it).
    var snapshot: (String) -> String? = { SinceLooked.tree(of: $0) }
    var diff: (String, String, String) -> [String] = { SinceLooked.files(from: $0, to: $1, in: $2) }
    var background: (@escaping () -> Void) -> Void
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        marks = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        let q = DispatchQueue(label: "octomux.since", qos: .utility)
        background = { q.async(execute: $0) }
    }

    /// When you last looked at the session (nil: never, as far as Octomux knows).
    func lookedAt(_ session: String) -> Date? {
        (marks[session]?[safe: 1]).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// You looked at the session now: its checkout as it is becomes the new starting point.
    func seen(_ session: String, path: String) {
        let snap = snapshot
        background { [weak self] in
            guard let tree = snap(path) else { return }
            self?.onMain {
                guard let self else { return }
                self.marks[session] = [tree, String(Date().timeIntervalSince1970), path]
                self.defaults.set(self.marks, forKey: Self.key)
                if self.changed[session] != [] { self.changed[session] = [] }
            }
        }
    }

    /// Files changed since you looked (cached; read again in the background at most every `every` seconds).
    func files(_ session: String, every: TimeInterval = 8) -> [String]? {
        guard let m = marks[session], m.count >= 3 else { return nil }
        if let t = asked[session], Date().timeIntervalSince(t) < every { return changed[session] }
        asked[session] = Date()
        let (tree, path) = (m[0], m[2]), snap = snapshot, d = diff
        background { [weak self] in
            guard let now = snap(path) else { return }
            let list = now == tree ? [] : d(tree, now, path)
            self?.onMain { if self?.changed[session] != list { self?.changed[session] = list } }
        }
        return changed[session]
    }

    /// The tree to compare a checkout with in Changes, when you ask for "since you looked".
    func tree(for session: String) -> String? { marks[session]?.first }

    func forget(_ session: String) {
        marks[session] = nil; changed[session] = nil
        defaults.set(marks, forKey: Self.key)
    }

    // MARK: Git

    /// The checkout as a tree: the index copied aside, every change added to the copy, the copy written as a tree.
    static func tree(of path: String) -> String? {
        guard let gitIndex = run(["rev-parse", "--git-path", "index"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let src = gitIndex.hasPrefix("/") ? gitIndex : (path as NSString).appendingPathComponent(gitIndex)
        let tmp = NSTemporaryDirectory() + "octomux-since-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        if FileManager.default.fileExists(atPath: src) { try? FileManager.default.copyItem(atPath: src, toPath: tmp) }
        let env = ["GIT_INDEX_FILE": tmp]
        guard run(["add", "-A"], in: path, env: env) != nil else { return nil }
        return run(["write-tree"], in: path, env: env)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func files(from a: String, to b: String, in path: String) -> [String] {
        (run(["diff", "--name-only", a, b], in: path) ?? "").split(separator: "\n").map(String.init)
    }

    static func run(_ args: [String], in dir: String, env: [String: String] = [:]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, b in b }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
