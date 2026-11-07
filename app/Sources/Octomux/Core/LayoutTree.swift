import Foundation

// The declarative layout engine: a layout's window is a JSON tree of rows, columns and stacks whose leaves are
// Octomux's own blocks. No code in a layout, only data: a tree that names a block we don't have, breaks a block's
// rules or doesn't parse is not used (the layout's built-in tree is, else the classic window).
//
//   {"schema": 1, "root": {"row": [
//       {"block": "agentRail", "size": {"fixed": 268}},
//       {"column": [{"block": "breadcrumb"}, {"stack": [{"block": "home"}, {"block": "workArea"}]}, {"block": "statusBar"}],
//        "size": {"flex": 1}}]}}
//
// Sizes run along the parent's axis: `fixed` points, `min` points (grows), `flex` weight. A stack shows one child:
// Home while the window is on its home, else the first other one.

/// The blocks a layout can place. Each knows where it may go and how small it may get.
enum ShellBlock: String, CaseIterable, Codable {
    case agentRail, projectTree, tabStrip, breadcrumb, workArea, home, sidePanel, statusBar

    enum Kind { case bar, rail, main }
    /// Bars go in a column (full width, their own height), rails in a row (their own width), main blocks anywhere.
    var kind: Kind {
        switch self {
        case .tabStrip, .breadcrumb, .statusBar: return .bar
        case .agentRail, .projectTree, .sidePanel: return .rail
        case .workArea, .home: return .main
        }
    }
    /// The smallest size along the parent's axis (points).
    var minSize: CGFloat {
        switch self {
        case .agentRail: return 220
        case .projectTree: return 200
        case .sidePanel: return 260
        case .workArea, .home: return 320
        case .tabStrip, .breadcrumb, .statusBar: return 0
        }
    }
    /// A rail's width when the layout gives none.
    var defaultWidth: CGFloat {
        switch self {
        case .agentRail: return 268
        case .projectTree: return 268
        case .sidePanel: return 320
        default: return 0
        }
    }
}

enum ShellSize: Equatable {
    case fixed(CGFloat), min(CGFloat), flex(Double)
}

indirect enum ShellNode: Equatable {
    case row([ShellChild]), column([ShellChild]), stack([ShellChild]), block(ShellBlock)

    var blocks: [ShellBlock] {
        switch self {
        case .block(let b): return [b]
        case .row(let c), .column(let c), .stack(let c): return c.flatMap(\.node.blocks)
        }
    }
}

struct ShellChild: Equatable {
    var node: ShellNode
    var size: ShellSize? = nil
}

struct ShellTree: Equatable {
    static let schema = 1
    var root: ShellNode

    enum Problem: Error, Equatable {
        case unreadable, schema(Int), unknownBlock(String), shape(String), twice(ShellBlock), placement(ShellBlock, String),
             tooSmall(ShellBlock), noWorkArea
    }

    // MARK: Reading

    static func parse(_ data: Data) -> Result<ShellTree, Problem> {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .failure(.unreadable) }
        return parse(v)
    }

    static func parse(_ v: JSONValue) -> Result<ShellTree, Problem> {
        guard case .object(let o) = v else { return .failure(.unreadable) }
        let schema = o["schema"].flatMap { if case .number(let n) = $0 { return Int(n) } else { return nil } } ?? 0
        guard schema == Self.schema else { return .failure(.schema(schema)) }
        guard let r = o["root"] else { return .failure(.shape("no root")) }
        do {
            let t = ShellTree(root: try child(r).node)
            if let p = t.problem() { return .failure(p) }
            return .success(t)
        } catch let p as Problem { return .failure(p) } catch { return .failure(.unreadable) }
    }

    private static func child(_ v: JSONValue) throws -> ShellChild {
        guard case .object(let o) = v else { throw Problem.shape("a node is not an object") }
        var size: ShellSize?
        if case .object(let s)? = o["size"] {
            if case .number(let n)? = s["fixed"] { size = .fixed(CGFloat(n)) }
            else if case .number(let n)? = s["min"] { size = .min(CGFloat(n)) }
            else if case .number(let n)? = s["flex"] { size = .flex(max(0.01, n)) }
            else { throw Problem.shape("size needs fixed, min or flex") }
        }
        let keys = ["row", "column", "stack", "block"].filter { o[$0] != nil }
        guard keys.count == 1 else { throw Problem.shape("a node needs exactly one of row, column, stack, block") }
        switch keys[0] {
        case "block":
            guard let name = o["block"]?.string else { throw Problem.shape("block needs a name") }
            guard let b = ShellBlock(rawValue: name) else { throw Problem.unknownBlock(name) }
            return ShellChild(node: .block(b), size: size)
        default:
            guard case .array(let list)? = o[keys[0]], !list.isEmpty else { throw Problem.shape("\(keys[0]) needs children") }
            let kids = try list.map(child)
            switch keys[0] {
            case "row": return ShellChild(node: .row(kids), size: size)
            case "column": return ShellChild(node: .column(kids), size: size)
            default: return ShellChild(node: .stack(kids), size: size)
            }
        }
    }

    // MARK: Rules

    /// What breaks the blocks' rules, if anything: each block once, a work area somewhere, bars in columns, rails in
    /// rows, nothing smaller than its block allows.
    func problem() -> Problem? {
        let all = root.blocks
        for b in ShellBlock.allCases where all.filter({ $0 == b }).count > 1 { return .twice(b) }
        guard all.contains(.workArea) else { return .noWorkArea }
        return check(root, parent: nil)
    }

    private func check(_ n: ShellNode, parent: String?, size: ShellSize? = nil) -> Problem? {
        switch n {
        case .block(let b):
            switch (b.kind, parent) {
            case (.bar, let p) where p != "column": return .placement(b, "a bar goes in a column")
            case (.rail, let p) where p != "row": return .placement(b, "a rail goes in a row")
            default: break
            }
            if case .fixed(let w)? = size, w < b.minSize { return .tooSmall(b) }
            if case .min(let w)? = size, w < b.minSize { return .tooSmall(b) }
            return nil
        case .row(let c): return c.lazy.compactMap { check($0.node, parent: "row", size: $0.size) }.first
        case .column(let c): return c.lazy.compactMap { check($0.node, parent: "column", size: $0.size) }.first
        case .stack(let c):
            // A stack's children fill it: only main blocks and containers.
            for k in c { if case .block(let b) = k.node, b.kind != .main { return .placement(b, "a stack holds main blocks") } }
            return c.lazy.compactMap { check($0.node, parent: "stack", size: $0.size) }.first
        }
    }

    // MARK: Built-in layouts (JSON files in Resources/layouts)

    static let dir: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("layouts"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Core
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // app
            .appendingPathComponent("Resources/layouts")
    }()

    nonisolated(unsafe) private static var builtInCache: [String: ShellTree?] = [:]

    /// A built-in layout's tree (nil: the layout uses the classic window).
    static func builtIn(_ name: String) -> ShellTree? {
        if let c = builtInCache[name] { return c }
        let url = dir.appendingPathComponent(name + ".json")
        let t = (try? Data(contentsOf: url)).flatMap { try? parse($0).get() }
        builtInCache[name] = t
        return t
    }

    /// A layout's tree: the user's own (`custom.<layout>.tree`) when it reads and keeps the rules, else the built-in.
    /// Rail widths the user dragged (`custom.<layout>.sizes`) go over it.
    static func resolve(preset: LayoutPreset, custom: [String: JSONValue]) -> ShellTree? {
        var t = custom["tree"].flatMap { try? parse($0).get() } ?? builtIn(preset.rawValue)
        if case .object(let sizes)? = custom["sizes"], t != nil {
            for (k, v) in sizes {
                guard let b = ShellBlock(rawValue: k), case .number(let w) = v, CGFloat(w) >= b.minSize else { continue }
                t!.root = t!.root.sized(b, .fixed(CGFloat(w)))
            }
        }
        return t
    }
}

extension ShellNode {
    /// The tree with `b`'s size replaced.
    func sized(_ b: ShellBlock, _ s: ShellSize) -> ShellNode {
        func walk(_ c: [ShellChild]) -> [ShellChild] {
            c.map { k in
                if case .block(let x) = k.node, x == b { return ShellChild(node: k.node, size: s) }
                return ShellChild(node: k.node.sized(b, s), size: k.size)
            }
        }
        switch self {
        case .block: return self
        case .row(let c): return .row(walk(c))
        case .column(let c): return .column(walk(c))
        case .stack(let c): return .stack(walk(c))
        }
    }

    /// A block's size as the tree gives it.
    func size(of b: ShellBlock) -> ShellSize? {
        func find(_ c: [ShellChild]) -> ShellSize?? {
            for k in c {
                if case .block(let x) = k.node, x == b { return .some(k.size) }
                if let s = k.node.sizeLookup(b) { return .some(s) }
            }
            return nil
        }
        switch self {
        case .block: return nil
        case .row(let c), .column(let c), .stack(let c): return find(c) ?? nil
        }
    }
    fileprivate func sizeLookup(_ b: ShellBlock) -> ShellSize? { size(of: b) }

    /// The child a stack shows: Home while the window is on its home, else the first child that isn't Home.
    static func shown(_ kids: [ShellChild], home: Bool) -> ShellChild? {
        if home, let h = kids.first(where: { $0.node == .block(.home) }) { return h }
        return kids.first { $0.node != .block(.home) } ?? kids.first
    }
}
