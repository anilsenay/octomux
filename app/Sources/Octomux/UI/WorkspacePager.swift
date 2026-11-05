import AppKit
import SwiftUI

/// Moves the sidebar's project list between workspaces: it follows two fingers while they swipe, then
/// slides out and the next workspace's list slides in from the other side (or it springs back when the
/// swipe was too short). Keyboard and the switcher dots get the same slide without the dragging.
final class WorkspacePager: ObservableObject {
    static let shared = WorkspacePager()

    /// Horizontal offset of the project list, in points.
    @Published private(set) var offset: CGFloat = 0

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var travel: CGFloat = 0          // finger travel this gesture
    private var velocity: CGFloat = 0        // points per event, smoothed
    private var sliding = false

    /// How far a swipe must go (or how fast) before it switches on release.
    static let commitDistance: CGFloat = 60
    static let commitVelocity: CGFloat = 12

    /// Swapped in tests.
    var workspaceCount: () -> Int = { AppModel.shared.state.workspaces.count }
    var commit: (Int) -> Void = { WorkspacePager.shared.slide($0) }
    var width: CGFloat { max(AppModel.shared.sidebarWidth, 160) }
    private var canSwitch: Bool { workspaceCount() > 1 }

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
            offset = rubberBand(travel)
        }
        if e.phase == .ended || e.phase == .cancelled {
            let fast = abs(velocity) > Self.commitVelocity && velocity.sign == travel.sign
            if canSwitch, e.phase == .ended, abs(travel) > Self.commitDistance || fast {
                // Fingers moved left → next workspace, the list leaves to the left.
                commit(travel < 0 ? 1 : -1)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
            }
            axis = .undecided; travel = 0; velocity = 0
        }
        return true
    }

    /// Follows the fingers one to one, then resists; with a single workspace it resists from the start.
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let limit = canSwitch ? width * 0.45 : 40
        let free = canSwitch ? width * 0.25 : 0
        let a = abs(x)
        if a <= free { return x }
        let over = a - free
        let damped = free + (limit - free) * (1 - 1 / (over / (limit - free) * 0.55 + 1))
        return damped * (x < 0 ? -1 : 1)
    }

    // MARK: Step

    /// Next (+1) or previous (-1) workspace with the slide (wrapping around, like cycleWorkspace).
    func slide(_ delta: Int) {
        let ws = AppModel.shared.state.workspaces.sorted { $0.sort < $1.sort }
        guard ws.count > 1, let i = ws.firstIndex(where: { $0.id == AppModel.shared.selectedWorkspaceId }) else {
            AppModel.shared.cycleWorkspace(delta); return
        }
        go(to: ws[(i + delta + ws.count) % ws.count].id, direction: delta)
    }

    /// A chosen workspace with the slide, leftward when it sits after the current one.
    func go(to id: String) {
        let ws = AppModel.shared.state.workspaces.sorted { $0.sort < $1.sort }
        let from = ws.firstIndex { $0.id == AppModel.shared.selectedWorkspaceId } ?? 0
        let to = ws.firstIndex { $0.id == id } ?? from
        go(to: id, direction: to >= from ? 1 : -1)
    }

    /// The list leaves toward -direction and the new one comes in from +direction.
    private func go(to id: String, direction: Int) {
        let model = AppModel.shared
        guard id != model.selectedWorkspaceId else { return }
        guard model.sidebarVisible, !sliding else { model.selectWorkspace(id); return }
        sliding = true
        let out = CGFloat(-direction) * width
        withAnimation(.easeIn(duration: 0.12)) { offset = out } completion: { [self] in
            model.selectWorkspace(id)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offset = -out * 0.6 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { offset = 0 } completion: { [self] in
                sliding = false
            }
        }
    }
}

/// Puts the pager's offset on the project list and fades it a little as it travels.
struct WorkspacePaged: ViewModifier {
    @ObservedObject var pager = WorkspacePager.shared
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        let w = max(model.sidebarWidth, 160)
        content
            .offset(x: pager.offset)
            .opacity(1 - min(abs(pager.offset) / w, 1) * 0.6)
            .clipped()
    }
}
