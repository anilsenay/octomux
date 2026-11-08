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
    case agentRail, projectTree, tasksRail, tabStrip, breadcrumb, workArea, home, sidePanel, taskDetail, sideAgent,
         aquariumStrip, statusBar

    enum Kind { case bar, rail, main }
    /// Bars go in a column (full width, their own height), rails in a row (their own width), main blocks anywhere.
    var kind: Kind {
        switch self {
        case .tabStrip, .breadcrumb, .statusBar, .aquariumStrip: return .bar
        case .agentRail, .projectTree, .tasksRail, .sidePanel, .taskDetail, .sideAgent: return .rail
        case .workArea, .home: return .main
        }
    }
    /// The smallest size along the parent's axis (points).
    var minSize: CGFloat {
        switch self {
        case .agentRail: return 220
        case .projectTree: return 200
        case .tasksRail: return 240
        case .sidePanel: return 260
        case .taskDetail, .sideAgent: return 280
        case .workArea, .home: return 320
        case .aquariumStrip: return 120
        case .tabStrip, .breadcrumb, .statusBar: return 0
        }
    }
    /// A rail's width (a bar's height) when the layout gives none; 0 = its own.
    var defaultWidth: CGFloat {
        switch self {
        case .agentRail: return 268
        case .projectTree: return 268
        case .tasksRail: return 300
        case .sidePanel: return 320
        case .taskDetail: return 340
        case .sideAgent: return 380
        case .aquariumStrip: return 210
        default: return 0
        }
    }
    /// The block's variants (`"variant": "workday"`); the first is the one without a variant. An unknown variant
    /// is read as the first (a later version's variant shows as today's block).
    var variants: [String] {
        switch self {
        case .home: return ["agents", "workday", "aquarium", "board"]
        default: return []
        }
    }
    /// Lists the window steps through with ⌘1…9 and ⌘[ ⌘] (instead of tabs).
    var isList: Bool { self == .agentRail || self == .tasksRail }
}

/// How the window moves between things: tabs (the tab strip), the agents on the rail, or the tasks on the rail.
enum ShellNav: Equatable { case tabs, agents, tasks }

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
    /// A block's variant (nil: its first).
    var variant: String? = nil

    /// A name that stays the same while the window shows it: the block's, or a container's first block (each block
    /// is placed once, so no two children share one).
    var key: String {
        switch node {
        case .block(let b): return b.rawValue
        case .row: return "row:" + (node.blocks.first?.rawValue ?? "")
        case .column: return "column:" + (node.blocks.first?.rawValue ?? "")
        case .stack: return "stack:" + (node.blocks.first?.rawValue ?? "")
        }
    }
}

struct ShellTree: Equatable {
    static let schema = 1
    var root: ShellNode

    enum Problem: Error, Equatable {
        case unreadable, schema(Int), unknownBlock(String), shape(String), twice(ShellBlock), placement(ShellBlock, String),
             tooSmall(ShellBlock), noWorkArea, twoLists

        /// For people: what is wrong with the file.
        var message: String {
            switch self {
            case .unreadable: return "It isn't JSON the layout engine can read."
            case .schema(let n): return n == 0 ? "It has no schema number." : "It is for layout schema \(n); this version reads schema \(ShellTree.schema)."
            case .unknownBlock(let b): return "It uses a block this version doesn't have: \(b)."
            case .shape(let s): return "Its tree is malformed: \(s)."
            case .twice(let b): return "It places \(b.rawValue) twice."
            case .placement(let b, let why): return "\(b.rawValue) is in the wrong place: \(why)."
            case .tooSmall(let b): return "\(b.rawValue) is smaller than \(Int(b.minSize)) points."
            case .noWorkArea: return "It has no workArea."
            case .twoLists: return "It has both agentRail and tasksRail (⌘1…9 can step through one list)."
            }
        }
    }

    /// The window's way of moving: the list it has, else tabs.
    var nav: ShellNav {
        let b = root.blocks
        if b.contains(.agentRail) { return .agents }
        if b.contains(.tasksRail) { return .tasks }
        return .tabs
    }
    func has(_ b: ShellBlock) -> Bool { root.blocks.contains(b) }
    /// The variant a block is placed with (nil: its first, or not placed).
    func variant(of b: ShellBlock) -> String? { root.variant(of: b) }

    // MARK: Reading

    static func parse(_ data: Data) -> Result<ShellTree, Problem> {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .failure(.unreadable) }
        return parse(v)
    }

    static func parse(_ v: JSONValue) -> Result<ShellTree, Problem> {
        guard case .object(let o) = v else { return .failure(.unreadable) }
        let schema = schemaNumber(o["schema"])
        guard schema == Self.schema else { return .failure(.schema(schema)) }
        guard let r = o["root"] else { return .failure(.shape("no root")) }
        do {
            var count = 0
            let t = ShellTree(root: try child(r, depth: 0, count: &count).node)
            if let p = t.problem() { return .failure(p) }
            return .success(t)
        } catch let p as Problem { return .failure(p) } catch { return .failure(.unreadable) }
    }

    /// A file's schema number; 0 when it has none or it isn't a whole number a layout could have (1e300 too).
    static func schemaNumber(_ v: JSONValue?) -> Int {
        guard case .number(let n)? = v, abs(n) < 1_000_000, let i = Int(exactly: n) else { return 0 }
        return i
    }
    /// Sizes a file can ask for: points no screen is wider than, and flex shares within reason.
    static let maxPoints: CGFloat = 4000, maxFlex = 100.0
    /// How deep and how big a tree may be: far more than any window uses, little enough for any file to be cheap.
    static let maxDepth = 12, maxNodes = 64
    private static func points(_ n: Double) -> CGFloat { CGFloat(min(max(n, 0), Double(maxPoints))) }

    private static func child(_ v: JSONValue, depth: Int, count: inout Int) throws -> ShellChild {
        guard case .object(let o) = v else { throw Problem.shape("a node is not an object") }
        guard depth < maxDepth else { throw Problem.shape("it nests deeper than \(maxDepth) levels") }
        count += 1
        guard count <= maxNodes else { throw Problem.shape("it has more than \(maxNodes) nodes") }
        var size: ShellSize?
        if case .object(let s)? = o["size"] {
            if case .number(let n)? = s["fixed"] { size = .fixed(points(n)) }
            else if case .number(let n)? = s["min"] { size = .min(points(n)) }
            else if case .number(let n)? = s["flex"] { size = .flex(min(max(0.01, n), maxFlex)) }
            else { throw Problem.shape("size needs fixed, min or flex") }
        }
        let keys = ["row", "column", "stack", "block"].filter { o[$0] != nil }
        guard keys.count == 1 else { throw Problem.shape("a node needs exactly one of row, column, stack, block") }
        switch keys[0] {
        case "block":
            guard let name = o["block"]?.string else { throw Problem.shape("block needs a name") }
            guard let b = ShellBlock(rawValue: name) else { throw Problem.unknownBlock(name) }
            let v = o["variant"]?.string.flatMap { b.variants.dropFirst().contains($0) ? $0 : nil }
            return ShellChild(node: .block(b), size: size, variant: v)
        default:
            guard case .array(let list)? = o[keys[0]], !list.isEmpty else { throw Problem.shape("\(keys[0]) needs children") }
            let kids = try list.map { try child($0, depth: depth + 1, count: &count) }
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
        if all.contains(.agentRail) && all.contains(.tasksRail) { return .twoLists }
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
                t!.root = t!.root.sized(b, .fixed(min(CGFloat(w), maxPoints)))
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
                if case .block(let x) = k.node, x == b { return ShellChild(node: k.node, size: s, variant: k.variant) }
                return ShellChild(node: k.node.sized(b, s), size: k.size, variant: k.variant)
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

    /// The variant `b` is placed with.
    func variant(of b: ShellBlock) -> String? {
        switch self {
        case .block: return nil
        case .row(let c), .column(let c), .stack(let c):
            for k in c {
                if case .block(let x) = k.node, x == b { return k.variant }
                if let v = k.node.variant(of: b) { return v }
            }
            return nil
        }
    }

    /// The child a stack shows: Home while the window is on its home, else the first child that isn't Home.
    static func shown(_ kids: [ShellChild], home: Bool) -> ShellChild? {
        if home, let h = kids.first(where: { $0.node == .block(.home) }) { return h }
        return kids.first { $0.node != .block(.home) } ?? kids.first
    }
}

// MARK: Writing (Save as new layout, Export)

extension ShellChild {
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        switch node {
        case .block(let b):
            o["block"] = .string(b.rawValue)
            if let v = variant { o["variant"] = .string(v) }
        case .row(let c): o["row"] = .array(c.map(\.json))
        case .column(let c): o["column"] = .array(c.map(\.json))
        case .stack(let c): o["stack"] = .array(c.map(\.json))
        }
        switch size {
        case .fixed(let n)?: o["size"] = .object(["fixed": .number(Double(n))])
        case .min(let n)?: o["size"] = .object(["min": .number(Double(n))])
        case .flex(let n)?: o["size"] = .object(["flex": .number(n)])
        case nil: break
        }
        return .object(o)
    }
}

extension ShellTree {
    /// The tree as a layout file stores it (`{"schema": 1, "root": …}`); reads back to the same tree.
    var json: JSONValue { .object(["schema": .number(Double(Self.schema)), "root": ShellChild(node: root).json]) }
}
