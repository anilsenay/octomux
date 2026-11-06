import AppKit
import SwiftUI

/// Pages the sidebar's project list between workspaces. While two fingers swipe, the current list moves
/// with them and the neighboring workspace's list comes in beside it; around the middle the window's
/// workspace color starts blending toward the neighbor's. Let go past the commit point (or with a flick)
/// and the neighbor finishes sliding in and becomes the workspace; otherwise both spring back.
/// Keyboard, ⌃N and the switcher dots run the same slide without the dragging.
final class WorkspacePager: ObservableObject {
    static let shared = WorkspacePager()

    /// Horizontal offset of the current list, in points: negative moves it left (the next workspace
    /// comes in from the right).
    @Published private(set) var offset: CGFloat = 0
    /// The workspace coming in (shown beside the current list while `offset` isn't 0).
    @Published private(set) var target: String?

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var travel: CGFloat = 0          // finger travel this gesture
    private var velocity: CGFloat = 0        // points per event, smoothed
    private var sliding = false

    /// Share of the sidebar width a swipe must cover (or a flick speed) to switch on release.
    static let commitShare: CGFloat = 0.4
    static let commitVelocity: CGFloat = 12

    /// Swapped in tests.
    var workspaceIds: () -> [String] = { AppModel.shared.orderedWorkspaces.map(\.id) }
    var currentId: () -> String? = { AppModel.shared.selectedWorkspaceId }
    var select: (String) -> Void = { AppModel.shared.selectWorkspace($0) }
    var animated = true
    var width: CGFloat { max(AppModel.shared.sidebarWidth, 160) }

    /// 0 at rest, 1 when the incoming list fills the sidebar.
    var progress: CGFloat { min(abs(offset) / width, 1) }
    /// How far the window color has moved toward the incoming workspace: starts around the middle of the swipe.
    var colorBlend: CGFloat {
        let t = min(max((progress - 0.2) / 0.6, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The workspace `delta` steps away, wrapping around (nil with a single workspace).
    func neighbor(_ delta: Int) -> String? {
        let ws = workspaceIds()
        guard ws.count > 1, let i = ws.firstIndex(where: { $0 == currentId() }) else { return nil }
        return ws[(i + delta + ws.count) % ws.count]
    }

    // MARK: Swipe

    /// One trackpad scroll event over the sidebar. Returns true when it belonged to a workspace swipe.
    @discardableResult
    func handle(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return false }
        if e.phase == .began || e.phase == .mayBegin {
            axis = .undecided; travel = 0; velocity = 0
            return false
        }
        if axis == .undecided {
            let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
            if dx + dy < 2 { return false }
            axis = dx > dy ? .horizontal : .vertical
        }
        guard axis == .horizontal, !sliding else { return false }
        if e.phase == .changed {
            travel += e.scrollingDeltaX
            velocity = velocity * 0.6 + e.scrollingDeltaX * 0.4
            // Fingers moving left bring in the next workspace from the right.
            target = travel == 0 ? nil : neighbor(travel < 0 ? 1 : -1)
            offset = target == nil ? rubberBand(travel) : max(-width, min(width, travel))
        }
        if e.phase == .ended || e.phase == .cancelled {
            let fast = abs(velocity) > Self.commitVelocity && velocity.sign == travel.sign
            if target != nil, e.phase == .ended, progress > Self.commitShare || fast {
                finish()
            } else {
                springBack()
            }
            axis = .undecided; travel = 0; velocity = 0
        }
        return true
    }

    /// With nowhere to go, the list only budges.
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let limit: CGFloat = 40
        return limit * (1 - 1 / (abs(x) / limit * 0.55 + 1)) * (x < 0 ? -1 : 1)
    }

    private func springBack() {
        guard offset != 0 else { target = nil; return }
        run(.spring(response: 0.32, dampingFraction: 0.82), { self.offset = 0 }) { self.target = nil }
    }

    /// Slides the incoming list the rest of the way, then makes it the workspace with nothing moving on screen.
    private func finish() {
        guard let id = target else { return }
        sliding = true
        let end: CGFloat = offset < 0 ? -width : width
        let rest = 1 - progress
        run(.spring(response: 0.22 + 0.16 * rest, dampingFraction: 0.95), { self.offset = end }) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                self.select(id)
                self.offset = 0
                self.target = nil
            }
            self.sliding = false
        }
    }

    private func run(_ a: Animation, _ change: @escaping () -> Void, completion: @escaping () -> Void) {
        if animated { withAnimation(a, change, completion: completion) } else { change(); completion() }
    }

    // MARK: Step

    /// Next (+1) or previous (-1) workspace with the slide (wrapping around, like cycleWorkspace).
    func slide(_ delta: Int) {
        guard let id = neighbor(delta) else { return }
        go(to: id, direction: delta)
    }

    /// A chosen workspace with the slide, coming in from the right when it sits after the current one.
    func go(to id: String) {
        let ws = workspaceIds()
        let from = ws.firstIndex { $0 == currentId() } ?? 0
        let to = ws.firstIndex { $0 == id } ?? from
        go(to: id, direction: to >= from ? 1 : -1)
    }

    private func go(to id: String, direction: Int) {
        guard id != currentId() else { return }
        guard (!animated || AppModel.shared.sidebarVisible), !sliding else { select(id); return }
        target = id
        offset = direction > 0 ? -0.001 : 0.001     // puts the incoming list on its side before it moves
        finish()
    }
}

/// The sidebar's project list for the current workspace, with the incoming one beside it while paging.
struct WorkspacePages<Page: View>: View {
    @ObservedObject var pager = WorkspacePager.shared
    let current: String?
    let page: (String) -> Page

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                if let c = current {
                    page(c).frame(width: w, height: geo.size.height).offset(x: pager.offset)
                }
                if let t = pager.target, t != current, pager.offset != 0 {
                    page(t).frame(width: w, height: geo.size.height)
                        .offset(x: pager.offset + (pager.offset < 0 ? w : -w))
                        .allowsHitTesting(false)
                }
            }
        }
        .clipped()
    }
}
