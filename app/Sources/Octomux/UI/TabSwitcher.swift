import AppKit
import SwiftUI

/// ⌃Tab tab switcher: while ⌃ is held, a strip of the current project's tabs (most recent first) with a picture of
/// each, its activity and title. ⌃Tab / ⌃⇧Tab move, releasing ⌃ opens the selected tab, Esc cancels.
/// Pictures are taken from our own window when a tab has been on screen (no other app is captured).
@MainActor
final class TabSwitcher: ObservableObject {
    static let shared = TabSwitcher()

    @Published private(set) var visible = false
    @Published private(set) var order: [String] = []     // tab ids, most recent first
    @Published var index = 0
    @Published private(set) var shots: [String: NSImage] = [:]

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var captureWork: DispatchWorkItem?
    private var lastTab: String?

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.keyDown(e) ? nil : e
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            if let self, self.visible, !e.modifierFlags.contains(.control) { self.commit() }
            return e
        }
        // A tab's picture: taken shortly after it is shown (the panes have drawn) and again before leaving it.
        Task { @MainActor in
            for await _ in AppModel.shared.$activeTabId.values {
                self.tabChanged()
            }
        }
    }

    private func tabChanged() {
        let model = AppModel.shared
        if let prev = lastTab, prev != model.activeTabId, shots[prev] == nil { /* left before its picture: keep none */ }
        lastTab = model.activeTabId
        scheduleCapture()
    }

    func scheduleCapture(after delay: Double = 0.6) {
        captureWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.captureCurrent() }
        captureWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// The work area of the main window (between the bars, right of the sidebar), scaled down.
    func captureCurrent() {
        let model = AppModel.shared
        guard let id = model.activeTabId, model.activeDoc == nil, !visible,
              let win = (NSApp.delegate as? AppDelegate)?.mainWindow, win.isVisible, win.occlusionState.contains(.visible),
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .nominalResolution])
        else { return }
        let m = T.m
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = w / max(1, win.frame.width)
        let left = (model.sidebarVisible ? model.sidebarWidth : 0) * scale
        let top = m.topH * scale, bottom = m.statusH * scale
        let rect = CGRect(x: left, y: top, width: max(1, w - left), height: max(1, h - top - bottom))
        guard let crop = cg.cropping(to: rect) else { return }
        let size = NSSize(width: 360, height: 360 * rect.height / max(1, rect.width))
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: crop, size: rect.size).draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        shots[id] = img
    }

    /// ⌃Tab / ⌃⇧Tab, and while open: arrows, Return, Esc. True when the event was used.
    private func keyDown(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTab = e.keyCode == 48
        if isTab && flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) {
            if visible { move(flags.contains(.shift) ? -1 : 1) } else { open(back: flags.contains(.shift)) }
            return true
        }
        guard visible else { return false }
        switch e.keyCode {
        case 53: cancel(); return true                       // esc
        case 36, 76: commit(); return true                   // return
        case 123, 126: move(-1); return true                 // ← ↑
        case 124, 125: move(1); return true                  // → ↓
        default: return true                                 // nothing reaches the terminal while open
        }
    }

    func open(back: Bool = false) {
        let model = AppModel.shared
        let tabs = model.currentTabs
        guard tabs.count > 1 else { return }
        captureCurrent()
        let ids = Set(tabs.map(\.id))
        var mru = model.tabHistory.reversed().filter { ids.contains($0) }
        for t in tabs where !mru.contains(t.id) { mru.append(t.id) }
        order = mru
        index = back ? mru.count - 1 : min(1, mru.count - 1)
        withAnimation(Motion.pop) { visible = true }
    }

    func move(_ d: Int) {
        guard !order.isEmpty else { return }
        index = (index + d + order.count) % order.count
    }

    func commit() {
        guard visible else { return }
        let id = order.indices.contains(index) ? order[index] : nil
        visible = false
        if let id { AppModel.shared.selectTab(id) }
    }

    func cancel() {
        visible = false
        TerminalHost.shared.focusCurrent()
    }

    func pick(_ i: Int) { index = i; commit() }
}

struct TabSwitcherOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var s = TabSwitcher.shared

    var body: some View {
        if s.visible {
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { s.cancel() }
                GeometryReader { geo in
                    let n = CGFloat(max(1, s.order.count))
                    let cardW = min(220, max(120, (geo.size.width - 120) / min(n, 6) - 12))
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(s.order.enumerated()), id: \.element) { i, id in
                                    card(id, selected: i == s.index, width: cardW)
                                        .id(id)
                                        .onTapGesture { s.pick(i) }
                                        .onHover { if $0 { s.index = i } }
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: s.index) { _, i in if s.order.indices.contains(i) { withAnimation(Motion.hover) { proxy.scrollTo(s.order[i], anchor: .center) } } }
                    }
                    .frame(maxWidth: min(geo.size.width - 60, (cardW + 12) * n + 20))
                    .background(RoundedRectangle(cornerRadius: R.float + 4, style: .continuous).fill(T.raised))
                    .overlay(RoundedRectangle(cornerRadius: R.float + 4, style: .continuous).stroke(T.border))
                    .shadow(color: .black.opacity(0.35), radius: 36, y: 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private func card(_ id: String, selected: Bool, width: CGFloat) -> some View {
        let tab = model.state.tabs.first { $0.id == id }
        let lead = model.session(tab?.activeSessionId ?? tab?.layout.sessions.first)
        let panes = tab?.layout.sessions.count ?? 1
        let h = width * 0.62
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: R.md, style: .continuous).fill(T.surface)
                if let img = s.shots[id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width, height: h, alignment: .topLeading).clipped()
                } else {
                    // Not on screen since launch: its mark instead of a picture.
                    AgentIcon(icon: lead.map { iconName(for: $0, model: model) } ?? "terminal", size: 26).opacity(0.7)
                }
            }
            .frame(width: width, height: h)
            .clipShape(RoundedRectangle(cornerRadius: R.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous)
                .strokeBorder(selected ? T.accent : T.border, lineWidth: selected ? 2 : 1))
            HStack(spacing: 6) {
                Text(lead?.displayTitle ?? "Tab").font(.system(size: T.k * 12, weight: .semibold))
                    .foregroundStyle(selected ? T.text : T.text2).lineLimit(1)
                Spacer(minLength: 0)
                if let lead { ActivityIndicator(session: lead).fixedSize() }
            }
            Text([model.profile(lead?.profileId)?.name ?? (lead?.isAgent == true ? "Agent" : "Terminal"),
                  panes > 1 ? "\(panes) panes" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(T.meta).foregroundStyle(T.text3).lineLimit(1)
                .padding(.top, -4)
        }
        .frame(width: width, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: R.lg + 2, style: .continuous).fill(selected ? T.hover : .clear))
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(Motion.hover, value: selected)
        .contentShape(Rectangle())
    }
}
