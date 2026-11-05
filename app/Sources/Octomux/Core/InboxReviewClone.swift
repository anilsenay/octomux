import Foundation

/// Clones kept for background reviews of repos you have no local clone of. Only what a review needs comes down:
/// a partial clone (history without file contents; files arrive as they are read), the pull request's head checked
/// out in a worktree next to it, Git LFS files skipped. A clone stays while it is used and goes after
/// `maxIdleDays` without a review, or from Settings → Inbox.
enum ReviewClones {
    static let maxIdleDays = 7.0
    static let marker = ".octomux-last-used"

    static var root: URL { Paths.home.appendingPathComponent("review-clones") }

    /// The clone's folder: review-clones/<source>/<workspace or owner>/<repo>.
    static func dir(for i: InboxItem, root: URL = root) -> String {
        let parts = i.place.lowercased().split(separator: "/").map { String($0).filter { $0.isLetter || $0.isNumber || "-_.".contains($0) } }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.reduce(root.appendingPathComponent(i.source.rawValue)) { $0.appendingPathComponent($1) }.path
    }

    /// Where its review worktrees go (beside the clone, so removing the clone's folder tree takes them too).
    static func worktree(for i: InboxItem, clone: String) -> String {
        clone + ".worktrees/review-\(i.number ?? 0)"
    }

    /// URLs to clone from, the way your other clones of that host are set up first (ssh or https).
    static func urls(for i: InboxItem, remotes: [String]) -> [String] {
        let host = i.source == .bitbucket ? "bitbucket.org" : "github.com"
        let ssh = "git@\(host):\(i.place).git", https = "https://\(host)/\(i.place).git"
        let known = remotes.filter { $0.contains(host) }
        if known.contains(where: { $0.hasPrefix("https://") }) && !known.contains(where: { $0.hasPrefix("git@") || $0.hasPrefix("ssh://") }) {
            return [https, ssh]
        }
        if known.contains(where: { $0.hasPrefix("git@") || $0.hasPrefix("ssh://") }) { return [ssh, https] }
        // Nothing to go by: GitHub's CLI usually sets git up for https; Bitbucket keys are usually ssh.
        return i.source == .github ? [https, ssh] : [ssh, https]
    }

    static func exists(_ dir: String) -> Bool { FileManager.default.fileExists(atPath: dir + "/.git") }

    /// Git that never waits for a password or a passphrase (it fails instead) and skips LFS downloads.
    static func git(_ args: [String], in dir: String?, skipLFS: Bool = true) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = (dir.map { ["-C", $0] } ?? []) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        if skipLFS { env["GIT_LFS_SKIP_SMUDGE"] = "1" }
        if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (false, "", "\(error)") }
        // Read both before waiting (a full pipe would block git).
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        e = err.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// Makes the clone when it isn't there yet and marks it used. Blocks (git over the network).
    static func ensure(_ i: InboxItem, remotes: [String], dir: String) throws {
        try ensure(i, urls: urls(for: i, remotes: remotes), dir: dir)
    }

    static func ensure(_ i: InboxItem, urls: [String], dir: String) throws {
        defer { touch(dir) }
        if exists(dir) { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var errors: [String] = []
        for url in urls {
            if fm.fileExists(atPath: dir) { try? fm.removeItem(atPath: dir) }   // what a failed try left
            let r = git(["clone", "--filter=blob:none", "--no-checkout", "--single-branch", "--no-tags", url, dir], in: nil)
            if r.ok {
                // LFS files stay pointers in the review worktree too.
                _ = git(["config", "filter.lfs.smudge", "git-lfs smudge --skip -- %f"], in: dir)
                _ = git(["config", "filter.lfs.process", "git-lfs filter-process --skip"], in: dir)
                return
            }
            errors.append("\(url): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "")")
        }
        if fm.fileExists(atPath: dir) { try? fm.removeItem(atPath: dir) }
        throw InboxError("Couldn't download \(i.place) (git needs access without asking for a password):\n" + errors.joined(separator: "\n"))
    }

    static func touch(_ dir: String) {
        guard FileManager.default.fileExists(atPath: dir) else { return }
        FileManager.default.createFile(atPath: dir + "/" + marker, contents: Data())
    }

    /// Every clone folder under the root (…/<source>/<owner>/<repo> holding a .git).
    static func all(root: URL = root) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for source in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let s = root.appendingPathComponent(source).path
            for owner in (try? fm.contentsOfDirectory(atPath: s)) ?? [] {
                let o = s + "/" + owner
                for repo in (try? fm.contentsOfDirectory(atPath: o)) ?? [] where !repo.hasSuffix(".worktrees") {
                    if exists(o + "/" + repo) { found.append(o + "/" + repo) }
                }
            }
        }
        return found
    }

    static func lastUsed(_ dir: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: dir + "/" + marker))?[.modificationDate] as? Date
    }

    /// Removes a clone and its review worktrees (only ever under the clones' folder).
    static func remove(_ dir: String, root: URL = root) {
        guard dir.hasPrefix(root.path + "/"), !dir.contains("/../") else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir + ".worktrees")
        try? fm.removeItem(atPath: dir)
    }

    /// Removes the clones unused for `maxIdleDays` (or all of them), except the ones in `busy`. Returns what went.
    @discardableResult
    static func prune(busy: Set<String>, all everything: Bool = false, now: Date = Date(), root: URL = root) -> [String] {
        var gone: [String] = []
        for d in all(root: root) where !busy.contains(d) {
            let idle = now.timeIntervalSince(lastUsed(d) ?? .distantPast) > maxIdleDays * 86400
            if everything || idle { remove(d, root: root); gone.append(d) }
        }
        return gone
    }

    /// The clones' size on disk, worktrees included.
    static func size(root: URL = root) -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// A full clone of a pull request's repo to work in (Clone into a Folder…), made a project.
enum RepoClone {
    static let parentKey = "octomux.inbox.cloneParent"

    /// Where clones go by default: the last folder used, else the folder most of your projects sit in, else ~.
    static func defaultParent(projects: [String], defaults: UserDefaults = .standard) -> String {
        if let p = defaults.string(forKey: parentKey), FileManager.default.fileExists(atPath: p) { return p }
        let parents = projects.map { ($0 as NSString).deletingLastPathComponent }
        let counts = Dictionary(parents.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Why `dest` can't take a clone, or nil.
    static func problem(_ dest: String) -> String? {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: dest, isDirectory: &dir) else { return nil }
        if !dir.boolValue { return "\((dest as NSString).abbreviatingWithTildeInPath) is a file." }
        if !((try? fm.contentsOfDirectory(atPath: dest)) ?? []).isEmpty { return "\((dest as NSString).abbreviatingWithTildeInPath) isn't empty." }
        return nil
    }

    /// Clones (ssh or https, as your other clones of that host; never asks for a password). Blocks.
    static func clone(_ i: InboxItem, remotes: [String], into dest: String) throws {
        try clone(i, urls: ReviewClones.urls(for: i, remotes: remotes), into: dest)
    }

    static func clone(_ i: InboxItem, urls: [String], into dest: String) throws {
        if let p = problem(dest) { throw InboxError(p) }
        var errors: [String] = []
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: dest)
        for url in urls {
            let r = ReviewClones.git(["clone", url, dest], in: nil, skipLFS: false)
            if r.ok { return }
            errors.append("\(url): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "")")
            if !existed { try? fm.removeItem(atPath: dest) }   // what the failed try left
        }
        throw InboxError("Couldn't clone \(i.place) (git needs access without asking for a password):\n" + errors.joined(separator: "\n"))
    }
}
