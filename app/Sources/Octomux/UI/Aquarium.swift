import SwiftUI

// The aquarium: one pixel octopus per agent, in its project's color. Working ones swim with bubbles, waiting ones
// bob with a "!", finished ones sleep on the sand (z z), idle ones rest there, a failed one shows "×". A click on an
// octopus opens its agent. Shown as a tab (View → Open Aquarium, any layout), as the strip above the panes in the
// Aquarium layout, and small behind the sidebar as the "Aquarium" scene.

struct AquariumFish: Equatable, Identifiable {
    enum Mood: Equatable { case working, waiting, finished, idle, error }
    var id: String
    var title: String
    var color: Color
    var mood: Mood

    static func moodOf(_ s: Session) -> Mood {
        if s.isDormant { return .idle }
        switch s.activity {
        case .working: return .working
        case .needsInput: return .waiting
        case .error: return .error
        case .done: return .finished
        case .idle: return s.unread ? .finished : .idle
        }
    }
}

enum AquariumMotion {
    /// 0…1 from an id, stable across launches.
    static func seed(_ id: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 10_000) / 10_000
    }

    /// Where an octopus is at time `t` (its top-left), for `count` octopuses in `size`. Sand is the bottom 18%.
    /// More than this many: two rows, the back one higher up the sand.
    static let oneRow = 8

    static func position(_ f: AquariumFish, index: Int, count: Int, t: Double, size: CGSize, sprite: CGSize) -> CGPoint {
        let s = seed(f.id)
        let rows = count > oneRow ? 2 : 1
        let row = rows == 2 ? index % 2 : 0                     // 1 = back row
        let inRow = rows == 2 ? (row == 0 ? (count + 1) / 2 : count / 2) : count
        let slot = rows == 2 ? index / 2 : index
        let start: CGFloat = row == 1 ? 0.75 : 0.5
        let lanes = CGFloat(max(1, inRow)) + (row == 1 ? 0.5 : 0)
        let lane = (CGFloat(slot) + start) / lanes
        let baseX = lane * size.width - sprite.width / 2
        let sandTop = size.height * 0.82
        // The back row sits a sprite and its label higher, so the front row never covers its names.
        let back = max(size.height * 0.1, sprite.height + 16)
        let restY = sandTop - sprite.height * 0.55 - (row == 1 ? back : 0)
        switch f.mood {
        case .working:
            let span = min(size.width / CGFloat(max(1, count)) * 0.9, 140)
            let x = baseX + span * CGFloat(sin(t * 0.35 + s * 6.28))
            let y = size.height * (0.22 + 0.3 * CGFloat(s)) + 10 * CGFloat(sin(t * 1.1 + s * 9))
            return CGPoint(x: x, y: y)
        case .waiting:
            return CGPoint(x: baseX, y: size.height * 0.38 + 5 * CGFloat(sin(t * 2.4 + s * 5)))
        case .finished, .error:
            return CGPoint(x: baseX, y: restY)
        case .idle:
            return CGPoint(x: baseX + 3 * CGFloat(sin(t * 0.4 + s * 4)), y: restY)
        }
    }

    /// The octopus under a point (the topmost), if any.
    static func hit(_ p: CGPoint, fish: [AquariumFish], t: Double, size: CGSize, sprite: CGSize) -> AquariumFish? {
        for (i, f) in fish.enumerated().reversed() {
            let o = position(f, index: i, count: fish.count, t: t, size: size, sprite: sprite)
            if CGRect(origin: o, size: sprite).insetBy(dx: -6, dy: -6).contains(p) { return f }
        }
        return nil
    }
}

struct AquariumView: View {
    enum Style { case full, strip, backdrop }
    // Not an environment object: scene tiles show it in windows without one.
    @ObservedObject private var model = AppModel.shared
    var style: Style = .full
    var still = false
    @State private var hovered: String?
    /// 12 frames a second while you're at it (pixel art moves in steps anyway); one a second behind other apps, or
    /// after 30 s without mouse or keyboard input and no agent changing state — still alive, for about the CPU of a
    /// still window (the cost goes with the frames: 12 a second ~7%, 1 ~0.4%).
    @State private var active = NSApp.isActive
    @State private var moodChanged = Date()
    @State private var lively = true
    static let restAfter: TimeInterval = 30

    /// Seconds between frames.
    static func frameInterval(style: Style, active: Bool) -> Double {
        if !active { return 1.0 }
        return style == .backdrop ? 1.0 / 8 : 1.0 / 12
    }

    /// Whether it swims at full speed: Octomux in front and someone around (input, or an agent changed state lately).
    static func isLively(active: Bool, idleSeconds: TimeInterval, sinceMoodChange: TimeInterval) -> Bool {
        active && (idleSeconds < restAfter || sinceMoodChange < restAfter)
    }

    private func refreshLively() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let l = Self.isLively(active: active, idleSeconds: idle, sinceMoodChange: Date().timeIntervalSince(moodChanged))
        if l != lively { lively = l }
    }

    static let eyeColor = Color(hex: "#1E1B4B")
    static let cheekColor = Color(hex: "#F9A8D4")

    static let rows = [
        ".....aaaaaa.....",
        "...abbbaaaaaa...",
        "..abbbaaaaaaaa..",
        ".aabbaaaaaaaaac.",
        ".aaaaaaaaaaaaac.",
        ".aaadeaaaadeaac.",
        ".aaaeeaaaaeeaac.",
        ".aaaeeaaaaeeaac.",
        ".afaaaaaaaaaafc.",
        "..aaaaaaaaaaac..",
        ".aa.aa.aa.aa.aa.",
        "aa..a..aa..a..aa",
        "a...a..aa..a...a",
    ]

    private var fish: [AquariumFish] {
        let agents = model.agentSessions(onlyCurrentWorkspace: style == .backdrop || style == .strip)
            .filter { !$0.isDormant || $0.lastActivityAt > Int(Date().timeIntervalSince1970) - 6 * 3600 }
            .sorted { $0.createdAt < $1.createdAt }
        return agents.prefix(style == .backdrop ? 6 : 24).map { s in
            AquariumFish(id: s.id, title: s.displayTitle, color: Color(hex: model.project(s.projectId)?.color ?? "#8B5CF6"), mood: AquariumFish.moodOf(s))
        }
    }

    private var px: CGFloat { style == .full ? 4 : style == .strip ? 3 : 2 }

    var body: some View {
        let list = fish
        let sprite = CGSize(width: 16 * px, height: 13 * px)
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: still ? 1000 : Self.frameInterval(style: style, active: lively), paused: still)) { tl in
                let t = still ? 37 : tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    if style != .backdrop { water(ctx, size, t) }
                    sand(ctx, size, t)
                    // The back row (odd places, when there are two) first, so the front row covers it.
                    let two = list.count > AquariumMotion.oneRow
                    let order = Array(list.enumerated()).filter { two && $0.offset % 2 == 1 } + Array(list.enumerated()).filter { !two || $0.offset % 2 == 0 }
                    let room = size.width / CGFloat(max(1, list.count > AquariumMotion.oneRow ? (list.count + 1) / 2 : list.count))
                    for (i, f) in order {
                        let o = AquariumMotion.position(f, index: i, count: list.count, t: t, size: size, sprite: sprite)
                        draw(f, at: o, ctx: ctx, t: t, bubble: style != .backdrop)
                        // A waiting one's name is in its bubble already.
                        if style != .backdrop && f.mood != .waiting { label(f, at: o, sprite: sprite, ctx: ctx, room: room) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { e in
                    guard style != .backdrop, let f = AquariumMotion.hit(e.location, fish: list, t: Date().timeIntervalSinceReferenceDate, size: g.size, sprite: sprite) else { return }
                    let s = model.session(f.id)
                    if s?.isDormant == true { model.restart(f.id) }
                    model.selectSession(f.id)
                })
            }
        }
        .allowsHitTesting(style != .backdrop)
        .opacity(style == .backdrop ? 0.6 : 1)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true; refreshLively() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false; refreshLively() }
        // Looks every 2 s whether anyone is around (cheap: one system call).
        .onReceive(Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common).autoconnect()) { _ in if !still, active { refreshLively() } }
        .onChange(of: list.map { "\($0.id)\($0.mood)" }) { _, _ in moodChanged = Date(); refreshLively() }
    }

    // MARK: Drawing

    private func water(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let dark = ThemeStore.shared.isDark
        let top = dark ? Color(hex: "#132A4A") : Color(hex: "#BFE3F5"), bottom = dark ? Color(hex: "#071426") : Color(hex: "#7CC3E6")
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        // Light from above.
        for i in 0..<4 {
            let x0 = size.width * (0.1 + 0.27 * CGFloat(i)) + 20 * CGFloat(sin(t * 0.1 + Double(i)))
            var p = Path()
            p.move(to: CGPoint(x: x0, y: 0)); p.addLine(to: CGPoint(x: x0 + 50, y: 0))
            p.addLine(to: CGPoint(x: x0 + 170, y: size.height)); p.addLine(to: CGPoint(x: x0 + 70, y: size.height)); p.closeSubpath()
            ctx.fill(p, with: .color(.white.opacity(dark ? 0.035 : 0.12)))
        }
        // Background bubbles.
        for i in 0..<18 {
            let s = AquariumMotion.seed("b\(i)")
            let speed = 18 + 24 * s
            let y = size.height - CGFloat((t * speed + s * 900).truncatingRemainder(dividingBy: Double(size.height + 20)))
            let x = size.width * CGFloat(s) + 6 * CGFloat(sin(t + s * 7))
            let r = 1.5 + 2 * CGFloat(s)
            ctx.stroke(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
    }

    private func sand(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let dark = ThemeStore.shared.isDark
        let top = size.height * 0.82
        var p = Path()
        p.move(to: CGPoint(x: 0, y: top))
        for x in stride(from: CGFloat(0), through: size.width, by: 24) { p.addLine(to: CGPoint(x: x, y: top + 4 * CGFloat(sin(Double(x) / 60)))) }
        p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: 0, y: size.height)); p.closeSubpath()
        ctx.fill(p, with: .color(dark ? Color(hex: "#3A3150") : Color(hex: "#E9D9B0")))
        // Weeds.
        let n = max(4, Int(size.width / 120))
        for i in 0..<n {
            let s = AquariumMotion.seed("w\(i)")
            let x = size.width * CGFloat(s)
            let h = 4 + Int(s * 6)
            for k in 0..<h {
                let sway = CGFloat(k) * 1.2 * CGFloat(sin(t * 0.8 + Double(i)))
                ctx.fill(Path(CGRect(x: x + sway, y: top - CGFloat(k + 1) * px * 2.5, width: px * 2, height: px * 2.5)),
                         with: .color((i % 2 == 0 ? Color(hex: "#4E8F7A") : Color(hex: "#3A7366")).opacity(0.9)))
            }
        }
    }

    private func draw(_ f: AquariumFish, at o: CGPoint, ctx: GraphicsContext, t: Double, bubble: Bool) {
        let body = f.color
        let light = f.color.opacity(0.55), shade = f.color.opacity(0.75)
        let sleeping = f.mood == .finished || f.mood == .idle
        // Legs move while it swims.
        let wiggle = f.mood == .working && Int(t * 4) % 2 == 0
        // One path per color (a few fills per octopus, not one per pixel: the strip redraws many times a second).
        enum Ink: Int { case body, light, shade, white, eye, cheek }
        var paths = [Path](repeating: Path(), count: 6)
        for (y, row) in Self.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let ink: Ink
                switch ch {
                case "a": ink = .body
                case "b": ink = .light
                case "c": ink = .shade
                case "d": ink = sleeping ? .body : .white
                case "e": ink = sleeping ? (y == 7 ? .eye : .body) : .eye
                case "f": ink = .cheek
                default: continue
                }
                var dx: CGFloat = 0
                if y >= 10 && wiggle { dx = (x % 2 == 0 ? 1 : -1) * px * 0.5 }
                paths[ink.rawValue].addRect(CGRect(x: o.x + CGFloat(x) * px + dx, y: o.y + CGFloat(y) * px, width: px, height: px))
            }
        }
        let inks: [Color] = [body, light, shade, .white, Self.eyeColor, Self.cheekColor]
        for (i, p) in paths.enumerated() where !p.isEmpty { ctx.fill(p, with: .color(inks[i])) }
        let w = 16 * px
        switch f.mood {
        case .working:
            for i in 0..<3 {
                let ph = (t * 0.9 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let r = px * (0.8 + CGFloat(i) * 0.3)
                let x = o.x + w * 0.5 + CGFloat(sin(t * 3 + Double(i))) * px * 2
                let y = o.y - CGFloat(ph) * px * 14
                ctx.stroke(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.7 * (1 - ph))), lineWidth: 1)
            }
        case .waiting:
            if bubble {
                // A speech bubble with its name: "! Review PR #42".
                let name = f.title.count > 18 ? String(f.title.prefix(17)) + "…" : f.title
                let text = ctx.resolve(Text("! " + name).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#B45309")))
                let ts = text.measure(in: CGSize(width: 400, height: 40))
                let box = CGRect(x: o.x + w * 0.5 - ts.width / 2 - 8, y: o.y - ts.height - 16, width: ts.width + 16, height: ts.height + 8)
                ctx.fill(Path(roundedRect: box, cornerRadius: 10), with: .color(Color(hex: "#FFF7E6")))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 10), with: .color(Color(hex: "#F59E0B")), lineWidth: 1.5)
                var tail = Path()
                tail.move(to: CGPoint(x: box.midX - 5, y: box.maxY)); tail.addLine(to: CGPoint(x: box.midX, y: box.maxY + 6)); tail.addLine(to: CGPoint(x: box.midX + 5, y: box.maxY))
                ctx.fill(tail, with: .color(Color(hex: "#FFF7E6")))
                ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            } else {
                ctx.draw(Text("!").font(.system(size: px * 6, weight: .heavy)).foregroundColor(Color(hex: "#F59E0B")), at: CGPoint(x: o.x + w * 0.5, y: o.y - px * 4))
            }
        case .finished:
            let ph = (t * 0.4).truncatingRemainder(dividingBy: 1)
            ctx.draw(Text("z").font(.system(size: px * 3.5, weight: .bold)).foregroundColor(.white.opacity(0.8 * (1 - ph))),
                     at: CGPoint(x: o.x + w * 0.8 + CGFloat(ph) * px * 3, y: o.y - CGFloat(ph) * px * 6))
            ctx.draw(Text("z").font(.system(size: px * 2.6, weight: .bold)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: o.x + w * 0.95, y: o.y - px * 6))
        case .error:
            ctx.draw(Text("×").font(.system(size: px * 6, weight: .heavy)).foregroundColor(Color(hex: "#EF4444")), at: CGPoint(x: o.x + w * 0.5, y: o.y - px * 3))
        case .idle: break
        }
    }

    /// The agent's name under it, cut to its lane (`room` points) so neighbours don't overlap.
    private func label(_ f: AquariumFish, at o: CGPoint, sprite: CGSize, ctx: GraphicsContext, room: CGFloat) {
        let fit = max(4, min(22, Int((room - 8) / 6.5)))
        let t = f.title.count > fit ? String(f.title.prefix(fit - 1)) + "…" : f.title
        ctx.draw(Text(t).font(.system(size: style == .full ? 11 : 10, weight: .medium)).foregroundColor(.white.opacity(0.9)),
                 at: CGPoint(x: o.x + sprite.width / 2, y: o.y + sprite.height + 9))
    }
}

/// The Aquarium tab: the aquarium, with a line saying who does what.
struct AquariumHomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        AquariumView(style: .full)
            .overlay(alignment: .top) { AquariumHeader(big: true).padding(.horizontal, 20).padding(.top, 16) }
    }
}

/// "Aquarium · 9 agents, one reef" and "2 swimming · 1 needs you · 6 resting".
struct AquariumHeader: View {
    @ObservedObject private var model = AppModel.shared
    var big = false

    static func counts(_ moods: [AquariumFish.Mood]) -> String {
        let swim = moods.filter { $0 == .working }.count, wait = moods.filter { $0 == .waiting || $0 == .error }.count
        let rest = moods.count - swim - wait
        return [swim > 0 ? "\(swim) swimming" : nil, wait > 0 ? "\(wait) need\(wait == 1 ? "s" : "") you" : nil, rest > 0 ? "\(rest) resting" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let agents = model.agentSessions(onlyCurrentWorkspace: !big).filter { !$0.isDormant || $0.lastActivityAt > Int(Date().timeIntervalSince1970) - 6 * 3600 }
        let moods = agents.map(AquariumFish.moodOf)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aquarium").font(.system(size: big ? 20 : 13, weight: .semibold))
                if big { Text(agents.isEmpty ? "An empty reef: start an agent (⌘N)." : "\(agents.count) agent\(agents.count == 1 ? "" : "s"), one reef.").font(T.meta) }
            }
            Spacer()
            Text(Self.counts(moods)).font(T.meta)
        }
        .foregroundStyle(.white.opacity(0.85))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}
