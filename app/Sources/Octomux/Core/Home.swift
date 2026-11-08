import Foundation

// Home: one page, the same in the Agents layout (its Home) and in the Terminal window (the Home tab). It is made of
// sections (today's parts of the Homes: the greeting, the composer, the agents waiting, your pull requests…) in three
// bands: a row on top, then a main column and a side column. A preset (Agents, Workday, Board, Aquarium) is a ready
// arrangement; Customize changes the one in use, saved at once in the global setting `ui.home`.

/// A part Home can show.
enum HomeSectionID: String, CaseIterable, Identifiable {
    case greeting, today, composer, stats, waiting, working, away, recent, pullRequests, reviews, issues, usage, board, aquarium
    var id: String { rawValue }

    var title: String {
        switch self {
        case .greeting: return "Greeting"
        case .today: return "Today"
        case .composer: return "Composer"
        case .stats: return "Stats"
        case .waiting: return "Waiting for you"
        case .working: return "Working"
        case .away: return "While you were away"
        case .recent: return "Recent"
        case .pullRequests: return "Your pull requests"
        case .reviews: return "Reviews for you"
        case .issues: return "Your issues"
        case .usage: return "Usage"
        case .board: return "Board"
        case .aquarium: return "Aquarium"
        }
    }
    var summary: String {
        switch self {
        case .greeting: return "hello, and who is waiting"
        case .today: return "the date, and what needs you"
        case .composer: return "start an agent"
        case .stats: return "needs you, working, reviews, usage"
        case .waiting: return "agents waiting, answered here"
        case .working: return "agents at work, their steps"
        case .away: return "finished agents, what happened"
        case .recent: return "your latest sessions"
        case .pullRequests: return "yours, with the next step"
        case .reviews: return "waiting on your review"
        case .issues: return "assigned to you"
        case .usage: return "your agents' limits"
        case .board: return "every agent by state"
        case .aquarium: return "every agent as an octopus"
        }
    }
    var icon: String {
        switch self {
        case .greeting: return "hand.wave"
        case .today: return "sun.max"
        case .composer: return "text.cursor"
        case .stats: return "square.grid.2x2"
        case .waiting: return "hand.raised"
        case .working: return "circle.dotted"
        case .away: return "arrow.uturn.backward"
        case .recent: return "clock"
        case .pullRequests: return "arrow.triangle.pull"
        case .reviews: return "checkmark.bubble"
        case .issues: return "smallcircle.filled.circle"
        case .usage: return "gauge.with.dots.needle.33percent"
        case .board: return "rectangle.split.3x1"
        case .aquarium: return "fish"
        }
    }
    /// A section as tall as the page when it is alone, else a tall strip on top (the others below it).
    var isBig: Bool { self == .board || self == .aquarium }
    /// The strip's height when a big section shares the page.
    var stripHeight: Double { self == .board ? 360 : 260 }
    /// Shows the agents' words (their digests: summaries, questions); the others read sessions or the Inbox only.
    var readsDigests: Bool { [.stats, .waiting, .working, .away, .board].contains(self) }
}

/// Where a section sits: the row on top, the main column, or the side column.
enum HomeBand: String, CaseIterable, Identifiable {
    case top, main, side
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// How wide Home's page is: today's Agents Home (narrow), today's Workday (wide), or the whole window.
enum HomeWidth: String, CaseIterable, Identifiable {
    case narrow, wide, full
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The page's widest (nil: the window's width).
    var points: Double? { switch self { case .narrow: return 980; case .wide: return 1200; case .full: return nil } }
}

/// The sections in their bands, in order (each section at most once), the page's width and the columns' split.
struct HomeLayout: Equatable {
    var top: [HomeSectionID] = []
    var main: [HomeSectionID] = []
    var side: [HomeSectionID] = []
    var width: HomeWidth = .wide
    /// The side column's share of the two columns' width (when both have sections).
    var split: Double = 0.5

    /// The split you can drag to: neither column narrower than a fifth.
    static let splitRange: ClosedRange<Double> = 0.2...0.8
    /// Today's Agents Home: a 300 pt side column on its 980 pt page (874 pt of columns once the 44 pt margins and the
    /// 18 pt gap are off). Splits are kept to three decimals, as stored.
    static let narrowSide = 0.343
    static func rounded(_ f: Double) -> Double { (min(max(f, splitRange.lowerBound), splitRange.upperBound) * 1000).rounded() / 1000 }

    subscript(b: HomeBand) -> [HomeSectionID] {
        get { switch b { case .top: return top; case .main: return main; case .side: return side } }
        set { switch b { case .top: top = newValue; case .main: main = newValue; case .side: side = newValue } }
    }
    var all: [HomeSectionID] { top + main + side }
    var isEmpty: Bool { all.isEmpty }
    func contains(_ s: HomeSectionID) -> Bool { all.contains(s) }
    func band(of s: HomeSectionID) -> HomeBand? { HomeBand.allCases.first { self[$0].contains(s) } }
    /// The sections Home doesn't show (what "+ Add section" offers).
    var missing: [HomeSectionID] { HomeSectionID.allCases.filter { !contains($0) } }

    /// Without `s`.
    func removing(_ s: HomeSectionID) -> HomeLayout {
        var l = self
        for b in HomeBand.allCases { l[b].removeAll { $0 == s } }
        return l
    }
    /// `s` put in band `b` at `index` (the end when nil or past it), taken from where it was.
    func moving(_ s: HomeSectionID, to b: HomeBand, at index: Int? = nil) -> HomeLayout {
        // The index counts in the band as it is drawn, with `s` still in it: moving down in its own band lands after
        // the section it was dropped on.
        var at = index ?? self[b].count
        if let i = self[b].firstIndex(of: s), i < at { at -= 1 }
        var l = removing(s)
        l[b].insert(s, at: max(0, min(at, l[b].count)))
        return l
    }

    /// The big section that fills the page: the only section, or the last one on top with nothing in the columns
    /// (Board: the composer above the board).
    var filling: HomeSectionID? {
        guard main.isEmpty, side.isEmpty, let last = top.last, last.isBig else { return nil }
        return last
    }

    /// Read from JSON: known sections only, each once (the first place wins); the width and split `base` has unless
    /// stored (and readable).
    static func read(_ o: [String: JSONValue], base: HomeLayout = HomeLayout()) -> HomeLayout {
        var seen = Set<HomeSectionID>()
        var l = HomeLayout(width: base.width, split: base.split)
        if let w = o["width"]?.string.flatMap(HomeWidth.init(rawValue:)) { l.width = w }
        if case .number(let n)? = o["split"], n.isFinite { l.split = rounded(n) }
        for b in HomeBand.allCases {
            guard case .array(let list)? = o[b.rawValue] else { continue }
            for v in list {
                guard let s = v.string.flatMap(HomeSectionID.init(rawValue:)), !seen.contains(s) else { continue }
                seen.insert(s)
                l[b].append(s)
            }
        }
        return l
    }
    var json: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        for b in HomeBand.allCases { o[b.rawValue] = .array(self[b].map { .string($0.rawValue) }) }
        o["width"] = .string(width.rawValue)
        o["split"] = .number(Self.rounded(split))
        return o
    }
}

/// A ready arrangement of Home.
enum HomePreset: String, CaseIterable, Identifiable {
    case agents, workday, board, aquarium
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agents"
        case .workday: return "Workday"
        case .board: return "Board"
        case .aquarium: return "Aquarium"
        }
    }
    var icon: String {
        switch self {
        case .agents: return "sparkles"
        case .workday: return "sun.max"
        case .board: return "rectangle.split.3x1"
        case .aquarium: return "fish"
        }
    }
    var summary: String {
        switch self {
        case .agents: return "start · waiting · recent"
        case .workday: return "your day"
        case .board: return "every agent by state"
        case .aquarium: return "every agent as an octopus"
        }
    }
    var layout: HomeLayout {
        switch self {
        case .agents: return HomeLayout(top: [.greeting, .composer], main: [.waiting], side: [.recent, .usage], width: .narrow, split: HomeLayout.narrowSide)
        case .workday: return HomeLayout(top: [.today, .stats], main: [.waiting, .away], side: [.pullRequests, .reviews, .issues], width: .wide, split: 0.5)
        case .board: return HomeLayout(top: [.composer, .board], width: .wide, split: 0.5)
        case .aquarium: return HomeLayout(top: [.aquarium], width: .wide, split: 0.5)
        }
    }
    /// A Home's name from before (a layout file's `"variant"`, the layout's `home`); unknown ones are Agents.
    static func named(_ s: String?) -> HomePreset {
        switch s {
        case "columns"?: return .board
        case let s?: return HomePreset(rawValue: s) ?? .agents
        case nil: return .agents
        }
    }
}

/// The Home in use: a preset, and what you changed in it (`ui.home`:
/// `{"preset": "agents", "top": […], "main": […], "side": […]}`; without the bands, the preset as it ships).
struct HomeSetting: Equatable {
    static let key = "ui.home"
    var preset: HomePreset
    /// Your arrangement; nil = the preset's.
    var custom: HomeLayout? = nil

    var layout: HomeLayout { custom ?? preset.layout }
    /// You changed the preset (the menu says "Agents (changed)" and offers Reset).
    var changed: Bool { custom != nil && custom != preset.layout }

    /// The setting as stored; nil when nothing (readable) is stored.
    static func read(_ v: JSONValue?) -> HomeSetting? {
        guard case .object(let o)? = v else { return nil }
        let p = HomePreset.named(o["preset"]?.string)
        let hasChanges = (HomeBand.allCases.map(\.rawValue) + ["width", "split"]).contains { o[$0] != nil }
        guard hasChanges else { return HomeSetting(preset: p) }
        var l = HomeLayout.read(o, base: p.layout)
        // Bands not stored (only the width or split changed): the preset's.
        for b in HomeBand.allCases where o[b.rawValue] == nil { l[b] = p.layout[b] }
        return HomeSetting(preset: p, custom: l == p.layout ? nil : l)
    }
    var json: JSONValue {
        var o = changed ? custom!.json : [:]
        o["preset"] = .string(preset.rawValue)
        return .object(o)
    }

    /// With the arrangement `l` (the preset's own is stored as no change).
    func with(_ l: HomeLayout) -> HomeSetting { HomeSetting(preset: preset, custom: l == preset.layout ? nil : l) }
}

extension AppModel {
    /// The Home you chose (`ui.home`); before you chose one, the Home the Agents layout had (a layout's `home`).
    var homeSetting: HomeSetting {
        if let h = HomeSetting.read(settingValue(HomeSetting.key, scope: "global")) { return h }
        return HomeSetting(preset: HomePreset.named(legacyHome))
    }
    /// The Home a version before the shared Home kept with the layout: the layout in use's, else the Agents layout's.
    private var legacyHome: String {
        if layout.home != "agents" { return layout.home }
        return LayoutConfig.resolve(LayoutEdit.choose(.agents, in: layoutStored), saved: savedLayouts).home
    }
    /// A layout file that names its Home (`"variant": "workday"`) shows that preset, whatever you chose.
    var homeFixedByTree: HomePreset? {
        guard let t = shellTree, t.has(.home), let v = t.variant(of: .home) else { return nil }
        return HomePreset.named(v)
    }
    /// What Home shows.
    var homeLayout: HomeLayout { homeFixedByTree?.layout ?? homeSetting.layout }

    func storeHome(_ h: HomeSetting) {
        setSettingLocally(HomeSetting.key, h.json, scope: "global")
        setSetting(HomeSetting.key, h.json.any, scope: "global")
    }
    /// The page's width (Customize).
    func setHomeWidth(_ w: HomeWidth) { var l = homeSetting.layout; l.width = w; setHomeLayout(l) }
    /// The side column's share (Customize: the line between the columns).
    func setHomeSplit(_ f: Double) {
        var l = homeSetting.layout
        l.split = HomeLayout.rounded(f)
        setHomeLayout(l)
    }
    /// A preset as it ships (Reset, or picking one in Home ⌄).
    func chooseHomePreset(_ p: HomePreset) { storeHome(HomeSetting(preset: p)) }
    /// Your arrangement of the preset in use (Customize; saved at once).
    func setHomeLayout(_ l: HomeLayout) { storeHome(homeSetting.with(l)) }
}
