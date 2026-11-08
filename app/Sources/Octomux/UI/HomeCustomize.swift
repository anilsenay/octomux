import SwiftUI
import UniformTypeIdentifiers

// Customize: Home edited in place. Each section gets a handle (drag it to another place, across the bands), its name
// and an eye (hide it: it stays faded until Done); "+ Add section" under each band offers the sections Home doesn't
// show. Every change is saved at once; Done only leaves the mode, Reset goes back to the preset.

/// Customize's state: on or off, the sections hidden while it is on (where they were), the one being dragged.
final class HomeCustomizeState: ObservableObject {
    static let shared = HomeCustomizeState()
    @Published var on = false
    @Published var hidden: [Hidden] = []
    @Published var dragging: HomeSectionID?
    /// The place a dragged section would land (band and index in the drawn bands).
    @Published var target: Place?

    struct Hidden: Equatable { let id: HomeSectionID; let band: HomeBand; let index: Int }
    struct Place: Equatable { let band: HomeBand; let index: Int }

    func start() { hidden = []; on = true }
    func done() { on = false; hidden = []; dragging = nil; target = nil }

    /// What Customize draws: your Home, with the sections you hid this time back where they were (faded).
    static func drawn(_ l: HomeLayout, hidden: [Hidden]) -> HomeLayout {
        var d = l
        for h in hidden where !l.contains(h.id) {
            d[h.band].insert(h.id, at: min(h.index, d[h.band].count))
        }
        return d
    }

    /// The eye: a shown section is hidden (taken off Home, faded here until Done); a hidden one comes back where it was.
    func toggleEye(_ id: HomeSectionID, model: AppModel) {
        let stored = model.homeSetting.layout
        let drawn = Self.drawn(stored, hidden: hidden)
        if let h = hidden.first(where: { $0.id == id }), !stored.contains(id) {
            let at = Self.storedIndex(drawn[h.band].firstIndex(of: id) ?? h.index, band: h.band, drawn: drawn, stored: stored)
            hidden.removeAll { $0.id == id }
            model.setHomeLayout(stored.moving(id, to: h.band, at: at))
        } else if let b = stored.band(of: id) {
            hidden.removeAll { $0.id == id }
            hidden.append(.init(id: id, band: b, index: drawn[b].firstIndex(of: id) ?? 0))
            model.setHomeLayout(stored.removing(id))
        }
    }

    /// A dragged section dropped at `place` (an index in the drawn band; Int.max: its end).
    func drop(_ s: HomeSectionID, at place: Place, model: AppModel) {
        let stored = model.homeSetting.layout
        let drawn = Self.drawn(stored, hidden: hidden)
        hidden.removeAll { $0.id == s }
        let at = Self.storedIndex(place.index, band: place.band, drawn: drawn, stored: stored)
        model.setHomeLayout(stored.moving(s, to: place.band, at: at))
    }

    /// A drop at `index` of the drawn band, as an index in your Home's band (the faded sections don't count).
    static func storedIndex(_ index: Int, band: HomeBand, drawn: HomeLayout, stored: HomeLayout) -> Int {
        drawn[band].prefix(index).filter { stored.contains($0) }.count
    }
}

/// Your Home (the one in `ui.home`): customized in place while Customize is on.
struct YourHome: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var c = HomeCustomizeState.shared
    var railFilter = true
    var body: some View {
        let l = model.homeLayout
        HomePage(layout: c.on ? HomeCustomizeState.drawn(l, hidden: c.hidden) : l, editing: model.homeEditing(c), railFilter: railFilter)
    }
}

extension AppModel {
    /// Customize's frame around Home's sections, for the Home you chose (nil while not customizing).
    func homeEditing(_ c: HomeCustomizeState) -> HomeEditing? {
        guard c.on else { return nil }
        return HomeEditing(
            toolbar: AnyView(HomeCustomizeBar()),
            bandLabel: { b in AnyView(Text(b.title).font(.system(size: T.k * 10, weight: .semibold)).tracking(0.6).foregroundStyle(T.text3)) },
            frame: { s, b, i, content in AnyView(HomeSectionFrame(id: s, band: b, index: i, content: content)) },
            addButton: { b in AnyView(HomeAddSection(band: b)) })
    }
}

/// "Customizing · Reset to Agents · Done" over the page.
struct HomeCustomizeBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var c = HomeCustomizeState.shared
    var body: some View {
        let h = model.homeSetting
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(T.icon(12)).foregroundStyle(T.accent)
            Text("Customizing Home").font(.system(size: T.k * 13, weight: .semibold))
            Text("Drag a section by its handle; changes are saved as you make them.").font(T.meta).foregroundStyle(T.text3).lineLimit(1)
            Spacer(minLength: 8)
            if h.changed || !c.hidden.isEmpty {
                Button("Reset to \(h.preset.title)") { c.hidden = []; model.chooseHomePreset(h.preset) }.buttonStyle(SmallButtonStyle())
            }
            Button("Done") { c.done() }.buttonStyle(SmallButtonStyle(prominent: true))
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: R.xl, style: .continuous).stroke(T.accent.opacity(0.5)))
    }
}

/// A section while customizing: handle, name and eye above it; it works but takes no clicks.
struct HomeSectionFrame: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var c = HomeCustomizeState.shared
    let id: HomeSectionID
    let band: HomeBand
    let index: Int
    let content: AnyView
    @State private var hoverEye = false

    private var isHidden: Bool { c.hidden.contains { $0.id == id } && !model.homeSetting.layout.contains(id) }

    var body: some View {
        let targeted = c.target == HomeCustomizeState.Place(band: band, index: index) && c.dragging != id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(T.icon(10, .semibold)).foregroundStyle(T.text3)
                    .frame(width: 16, height: 16).help("Drag to move")
                Image(systemName: id.icon).font(T.icon(10)).foregroundStyle(T.text3)
                Text(id.title).font(.system(size: T.k * 11, weight: .medium)).foregroundStyle(T.text2)
                if isHidden { Text("hidden").font(T.meta).foregroundStyle(T.text3) }
                Spacer(minLength: 4)
                Button { eye() } label: {
                    Image(systemName: isHidden ? "eye.slash" : "eye").font(T.icon(11)).foregroundStyle(hoverEye ? T.text : T.text3)
                        .frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { hoverEye = $0 }.pointerCursor()
                .help(isHidden ? "Show this section" : "Hide this section")
            }
            .contentShape(Rectangle())
            .onDrag {
                c.dragging = id
                return NSItemProvider(object: id.rawValue as NSString)
            }
            content
                .allowsHitTesting(false)
                .opacity(isHidden ? 0.35 : 1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: R.xl + 4, style: .continuous).strokeBorder(T.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .overlay(alignment: .top) {
            if targeted { Capsule().fill(T.accent).frame(height: 3).offset(y: -6) }
        }
        .opacity(c.dragging == id ? 0.5 : 1)
        .onDrop(of: [UTType.text], delegate: HomeDrop(place: .init(band: band, index: index), model: model))
    }

    private func eye() { c.toggleEye(id, model: model) }
}

/// Dropping a dragged section: it goes before the section it is dropped on, or at the end of the band.
struct HomeDrop: DropDelegate {
    let place: HomeCustomizeState.Place
    let model: AppModel
    var c: HomeCustomizeState { .shared }

    func dropEntered(info: DropInfo) { c.target = place }
    func dropExited(info: DropInfo) { if c.target == place { c.target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        defer { c.dragging = nil; c.target = nil }
        guard let s = c.dragging else { return false }
        c.drop(s, at: place, model: model)
        return true
    }
}

/// "+ Add section" under a band: Octomux's panel with the sections Home doesn't show; also where a dragged section
/// lands at the band's end.
struct HomeAddSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var c = HomeCustomizeState.shared
    let band: HomeBand
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let targeted = c.target == HomeCustomizeState.Place(band: band, index: Int.max)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(T.icon(10, .semibold))
                Text("Add section").font(.system(size: T.k * 12, weight: .medium))
            }
            .foregroundStyle(hover || open ? T.text : T.text3)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: R.xl, style: .continuous)
                .strokeBorder(targeted ? T.accent : T.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.pointerCursor()
        .floatingPanel(isPresented: $open, alignment: .leading) { HomeAddPanel(band: band) }
        .debugOpens("home_add_\(band.rawValue)", $open)
        .onDrop(of: [UTType.text], delegate: HomeDrop(place: .init(band: band, index: Int.max), model: model))
    }
}

/// The sections Home doesn't show, with what each is.
struct HomeAddPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav = PanelNav()
    let band: HomeBand
    var body: some View {
        let missing = model.homeSetting.layout.missing
        PanelCard(width: 360) {
            PanelSectionTitle("Add to \(band.rawValue)")
            if missing.isEmpty { Text("Every section is on Home.").font(T.meta).foregroundStyle(T.text3).padding(9) }
            ForEach(Array(missing.enumerated()), id: \.element) { i, s in
                PanelRow(title: s.title, detail: s.summary, highlighted: nav.index == i) {
                    Image(systemName: s.icon).font(T.icon(11)).foregroundStyle(T.text3)
                }
                .onHover { on in if on { nav.index = i } else if nav.index == i { nav.index = nil } }
                .onTapGesture { nav.run(i) }
                .panelPointer()
            }
        }
        .onAppear {
            nav.set(missing.map { s in {
                let c = HomeCustomizeState.shared
                c.hidden.removeAll { $0.id == s }
                model.setHomeLayout(model.homeSetting.layout.moving(s, to: band))
            } })
            nav.attach()
        }
    }
}
