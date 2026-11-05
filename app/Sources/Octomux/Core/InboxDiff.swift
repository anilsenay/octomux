import Foundation

/// A pull request's changes as `gh pr diff` prints them (a unified diff), split into files, hunks and lines.
enum InboxDiff {
    struct Line: Equatable {
        enum Kind: Equatable { case context, added, removed, note }
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    struct Hunk: Equatable {
        let header: String          // "@@ -10,6 +10,8 @@ func x()"
        var lines: [Line]
    }

    struct File: Equatable, Identifiable {
        var path: String
        var oldPath: String?
        var status: String = "M"     // A added, D deleted, R renamed, M modified
        var binary = false
        var hunks: [Hunk] = []
        var id: String { path }
        var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
        var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    }

    /// Parses a unified diff. Paths come from the `diff --git a/… b/…` line, made exact by `---` / `+++` and rename lines.
    static func parse(_ diff: String) -> [File] {
        var files: [File] = []
        var cur: File?
        var hunk: Hunk?
        var oldN = 0, newN = 0

        func closeHunk() { if let h = hunk { cur?.hunks.append(h) }; hunk = nil }
        func closeFile() { closeHunk(); if let f = cur { files.append(f) }; cur = nil }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                let rest = line.dropFirst("diff --git ".count)
                // "a/x b/x": the b side, split at " b/" (paths may contain spaces).
                let path = rest.range(of: " b/").map { String(rest[$0.upperBound...]) } ?? String(rest)
                cur = File(path: path)
                continue
            }
            guard cur != nil else { continue }
            if hunk == nil || line.hasPrefix("@@") {
                if line.hasPrefix("new file mode") { cur?.status = "A"; continue }
                if line.hasPrefix("deleted file mode") { cur?.status = "D"; continue }
                if line.hasPrefix("rename from ") { cur?.oldPath = String(line.dropFirst("rename from ".count)); cur?.status = "R"; continue }
                if line.hasPrefix("rename to ") { cur?.path = String(line.dropFirst("rename to ".count)); continue }
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" { cur?.binary = true; continue }
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                    let p = String(line.dropFirst(4))
                    if line.hasPrefix("+++ "), p != "/dev/null" { cur?.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
                    continue
                }
                if line.hasPrefix("@@") {
                    closeHunk()
                    // @@ -a,b +c,d @@
                    let nums = line.split(separator: " ").dropFirst().prefix(2)
                    func start(_ s: Substring?) -> Int { Int((s ?? "").dropFirst().split(separator: ",").first ?? "") ?? 0 }
                    oldN = start(nums.first); newN = start(nums.dropFirst().first)
                    hunk = Hunk(header: line, lines: [])
                    continue
                }
                if hunk == nil { continue }        // index, mode and similarity lines
            }
            guard hunk != nil else { continue }
            switch line.first {
            case "+": hunk?.lines.append(Line(kind: .added, old: nil, new: newN, text: String(line.dropFirst()))); newN += 1
            case "-": hunk?.lines.append(Line(kind: .removed, old: oldN, new: nil, text: String(line.dropFirst()))); oldN += 1
            case " ": hunk?.lines.append(Line(kind: .context, old: oldN, new: newN, text: String(line.dropFirst()))); oldN += 1; newN += 1
            case "\\": hunk?.lines.append(Line(kind: .note, old: nil, new: nil, text: String(line.dropFirst(2))))
            case nil: continue                    // the empty line at the very end
            default: continue
            }
        }
        closeFile()
        return files
    }

    static func fetch(_ item: InboxItem) throws -> String {
        guard let repo = item.repo, let n = item.number else { return "" }
        return try InboxShell.run(["gh", "pr", "diff", "\(n)", "--repo", repo])
    }
}
