import Foundation

/// What changed between two page snapshots (YAML trees, two spaces per level), for agents: changed lines with `+`
/// (new or changed) and `-` (gone), each under its unchanged parent lines so it reads in place.
enum SnapshotDiff {
    struct Result: Equatable {
        var text: String
        var added: Int
        var removed: Int
        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    private enum Op { case same(Int, Int), add(Int), del(Int) }

    /// Nil when the pages differ too much for a diff to help (send the whole snapshot instead).
    static func diff(old: String, new: String, maxChanged: Int = 400) -> Result? {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let ops = lineOps(a, b) else { return nil }
        let added = ops.filter { if case .add = $0 { return true }; return false }.count
        let removed = ops.filter { if case .del = $0 { return true }; return false }.count
        if added == 0 && removed == 0 { return Result(text: "", added: 0, removed: 0) }
        if added + removed > maxChanged || Double(added) > Double(max(b.count, 1)) * 0.6 { return nil }

        func line(_ op: Op) -> String {
            switch op { case .same(_, let j): return b[j]; case .add(let j): return b[j]; case .del(let i): return a[i] }
        }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        // Each changed line, plus the unchanged lines above it that are its parents.
        var keep = Set<Int>()
        for (k, op) in ops.enumerated() {
            if case .same = op { continue }
            keep.insert(k)
            var level = indent(line(op))
            var j = k - 1
            while level > 0 && j >= 0 {
                if case .same = ops[j], indent(line(ops[j])) < level {
                    keep.insert(j)
                    level = indent(line(ops[j]))
                }
                j -= 1
            }
        }
        var out: [String] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0 && k > last + 1 && !out.isEmpty { out.append("  ⋯") }
            switch ops[k] {
            case .same: out.append("  " + line(ops[k]))
            case .add: out.append("+ " + line(ops[k]))
            case .del: out.append("- " + line(ops[k]))
            }
            last = k
        }
        return Result(text: out.joined(separator: "\n"), added: added, removed: removed)
    }

    /// Line-level edit script (LCS), after trimming the common start and end. Nil if the changed middle is too
    /// large to compare cheaply.
    private static func lineOps(_ a: [String], _ b: [String]) -> [Op]? {
        var pre = 0
        while pre < a.count && pre < b.count && a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre && suf < b.count - pre && a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let a2 = Array(a[pre..<(a.count - suf)]), b2 = Array(b[pre..<(b.count - suf)])
        let n = a2.count, m = b2.count
        guard n * m <= 4_000_000 else { return nil }
        var ops: [Op] = (0..<pre).map { .same($0, $0) }
        if n == 0 || m == 0 {
            ops += (0..<n).map { .del(pre + $0) }
            ops += (0..<m).map { .add(pre + $0) }
        } else {
            // dp[i][j] = LCS of a2[i...] and b2[j...], flattened.
            var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i * (m + 1) + j] = a2[i] == b2[j] ? dp[(i + 1) * (m + 1) + j + 1] + 1 : max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if a2[i] == b2[j] { ops.append(.same(pre + i, pre + j)); i += 1; j += 1 }
                else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] { ops.append(.del(pre + i)); i += 1 }
                else { ops.append(.add(pre + j)); j += 1 }
            }
            while i < n { ops.append(.del(pre + i)); i += 1 }
            while j < m { ops.append(.add(pre + j)); j += 1 }
        }
        ops += (0..<suf).map { .same(a.count - suf + $0, b.count - suf + $0) }
        return ops
    }
}
