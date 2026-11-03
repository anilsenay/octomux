import CoreGraphics

/// Pane sizes after a split, so repeated splits don't halve one pane down to a sliver:
/// - Panes split one after another in the same direction (a run: nested splits of one direction) share
///   their space equally (2 → ½ ½, 3 → ⅓ ⅓ ⅓ …).
/// - Every other split keeps its ratio, unless a side would fall under the minimum pane size; then the
///   divider moves just enough (a full row squeezes the pane beside it).
/// - If the panes can't fit even then, there is no split (nil).
enum SplitSizing {
    static let minWidth: CGFloat = 160
    static let minHeight: CGFloat = 110

    /// The tab's layout once `target` is split with a new pane in `dir`, with sizes for a container of `size`.
    static func layout(splitting target: String, dir: SplitDir, in layout: PaneNode, size: CGSize,
                       divider: CGFloat, newId: String = "\u{0}new") -> PaneNode? {
        guard let split = layout.splitting(target, newId: newId, dir: dir) else { return nil }
        return fitted(split, size: size, divider: divider, even: evenPaths(split, newId: newId, dir: dir))
    }

    /// Every row and column of the tab at equal shares (each split as if the panes had just been opened
    /// in it), then minimum sizes as for a split. If even the minimums don't fit, equal shares only.
    static func equalized(_ layout: PaneNode, size: CGSize, divider: CGFloat) -> PaneNode {
        var all: Set<[Bool]> = []
        func collect(_ n: PaneNode, _ p: [Bool]) {
            guard case .split(_, _, let a, let b) = n else { return }
            all.insert(p); collect(a, p + [false]); collect(b, p + [true])
        }
        collect(layout, [])
        return fitted(layout, size: size, divider: divider, even: all)
            ?? fit(layout, size, divider, all, [], minimums: false)
    }

    /// Pre-order ratios of a tree (what `session.create`'s `split_ratios` takes).
    static func ratios(_ n: PaneNode) -> [Double] {
        guard case .split(_, let r, let a, let b) = n else { return [] }
        return [r] + ratios(a) + ratios(b)
    }

    // MARK: - Equal shares in the new pane's run

    /// Paths of the splits that make up the new pane's run: from the topmost split above the new pane
    /// reached through splits of `dir` only, every split of `dir` below it (through `dir` splits).
    static func evenPaths(_ n: PaneNode, newId: String, dir: SplitDir) -> Set<[Bool]> {
        guard let path = n.path(to: newId), !path.isEmpty else { return [] }
        // `path.prefix(k)` is a split; start at the one holding the new leaf, go up while the parent splits in `dir`.
        var k = path.count - 1
        while k > 0, case .split(let d, _, _, _)? = n.node(at: Array(path.prefix(k - 1))), d == dir { k -= 1 }
        var out: Set<[Bool]> = []
        func collect(_ node: PaneNode, _ p: [Bool]) {
            guard case .split(let d, _, let a, let b) = node, d == dir else { return }
            out.insert(p)
            collect(a, p + [false]); collect(b, p + [true])
        }
        let top = Array(path.prefix(k))
        if let root = n.node(at: top) { collect(root, top) }
        return out
    }

    /// Panes side by side in `dir` within a run (a split of another direction counts as one).
    static func items(_ n: PaneNode, _ dir: SplitDir) -> Int {
        if case .split(let d, _, let a, let b) = n, d == dir { return items(a, dir) + items(b, dir) }
        return 1
    }

    // MARK: - Minimum sizes

    /// Smallest extent the subtree needs along an axis (`.right` = width, `.down` = height).
    static func need(_ n: PaneNode, _ axis: SplitDir, divider: CGFloat) -> CGFloat {
        switch n {
        case .leaf: return axis == .right ? minWidth : minHeight
        case .split(let d, _, let a, let b):
            let na = need(a, axis, divider: divider), nb = need(b, axis, divider: divider)
            return d == axis ? na + nb + divider : max(na, nb)
        }
    }

    /// Sizes top-down: splits in `even` get equal panes (dividers counted), every split then moves only
    /// as far as needed for each pane to keep its minimum. nil when the container is too small for all.
    static func fitted(_ n: PaneNode, size: CGSize, divider: CGFloat, even: Set<[Bool]> = []) -> PaneNode? {
        guard need(n, .right, divider: divider) <= size.width + 0.5, need(n, .down, divider: divider) <= size.height + 0.5 else { return nil }
        return fit(n, size, divider, even, [], minimums: true)
    }

    private static func fit(_ n: PaneNode, _ size: CGSize, _ div: CGFloat, _ even: Set<[Bool]>, _ path: [Bool], minimums: Bool) -> PaneNode {
        guard case .split(let d, var r, let a, let b) = n else { return n }
        let extent = d == .right ? size.width : size.height
        let total = extent - div
        guard total > 1 else { return n }
        if even.contains(path) {
            let na = CGFloat(items(a, d)), nb = CGFloat(items(b, d)), count = na + nb
            let pane = (extent - (count - 1) * div) / count
            r = Double((na * pane + (na - 1) * div) / total)
        }
        let lo = need(a, d, divider: div) / total, hi = 1 - need(b, d, divider: div) / total
        if minimums, lo <= hi { r = min(max(r, Double(lo)), Double(hi)) }
        let first = total * CGFloat(r), second = total - first
        let sa = d == .right ? CGSize(width: first, height: size.height) : CGSize(width: size.width, height: first)
        let sb = d == .right ? CGSize(width: second, height: size.height) : CGSize(width: size.width, height: second)
        return .split(dir: d, ratio: r, a: fit(a, sa, div, even, path + [false], minimums: minimums), b: fit(b, sb, div, even, path + [true], minimums: minimums))
    }
}

extension PaneNode {
    /// Same as the daemon's split: `target` becomes (target, new) in `dir`, ratio ½.
    func splitting(_ target: String, newId: String, dir: SplitDir) -> PaneNode? {
        switch self {
        case .leaf(let id):
            return id == target ? .split(dir: dir, ratio: 0.5, a: self, b: .leaf(sessionId: newId)) : nil
        case .split(let d, let r, let a, let b):
            if let a2 = a.splitting(target, newId: newId, dir: dir) { return .split(dir: d, ratio: r, a: a2, b: b) }
            if let b2 = b.splitting(target, newId: newId, dir: dir) { return .split(dir: d, ratio: r, a: a, b: b2) }
            return nil
        }
    }

    /// Path to the leaf `id` (false = a, true = b).
    func path(to id: String) -> [Bool]? {
        switch self {
        case .leaf(let s): return s == id ? [] : nil
        case .split(_, _, let a, let b):
            if let p = a.path(to: id) { return [false] + p }
            if let p = b.path(to: id) { return [true] + p }
            return nil
        }
    }

    func node(at path: [Bool]) -> PaneNode? {
        guard let first = path.first else { return self }
        guard case .split(_, _, let a, let b) = self else { return nil }
        return (first ? b : a).node(at: Array(path.dropFirst()))
    }

    func replacing(at path: [Bool], with new: PaneNode) -> PaneNode {
        guard let first = path.first else { return new }
        guard case .split(let d, let r, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        return first ? .split(dir: d, ratio: r, a: a, b: b.replacing(at: rest, with: new))
                     : .split(dir: d, ratio: r, a: a.replacing(at: rest, with: new), b: b)
    }
}
