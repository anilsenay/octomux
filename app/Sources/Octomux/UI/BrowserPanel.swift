import AppKit
import SwiftUI
import WebKit

/// The Octomux browser beside a tab's terminals (half the work area by default, resized from its left edge): the
/// pages agents drive through their browser tools while the user watches (cursor, action label, framed element),
/// or browses themselves. Each tab remembers whether it shows the browser and which page.
struct BrowserSplit: View {
    let tab: String
    @ObservedObject var store = BrowserStore.shared

    var body: some View {
        if let page = store.splitPage(tab: tab) {
            BrowserPageView(page: page, tab: tab).id(page.id)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { store.closeSplit(tab: tab) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 24)).help("Close Browser")
                }
                .padding(.horizontal, 6).frame(height: 36)
                Hairline()
                VStack(spacing: 10) {
                    PanelEmpty(icon: "globe", text: "No page here").frame(height: 90)
                    Text("Agents open pages beside their tab when they use the browser, and you can watch them work.")
                        .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 280)
                    Button { BrowserUI.newUserPage(tab: tab) } label: { Label("New Page", systemImage: "plus") }
                        .buttonStyle(ChromeButtonStyle()).font(T.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The work area with the active tab's browser (if open) on the right, split by a draggable edge.
struct WorkAreaWithBrowser<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = BrowserStore.shared
    /// The browser's share of the work area's width.
    @AppStorage("octomux.browserSplit") private var ratio = 0.5
    @ViewBuilder var content: Content

    var body: some View {
        let tab = model.activeDoc == nil ? model.activeTabId : nil
        let open = tab.map { store.splitOpen(tab: $0) } ?? false
        // One structure whether the browser shows or not: the terminals keep their place (and their shared view)
        // when it opens or closes.
        GeometryReader { g in
            HStack(spacing: open ? T.m.inset : 0) {
                content.frame(maxWidth: .infinity)
                if open, let tab {
                    BrowserSplit(tab: tab)
                        .frame(width: max(320, min(g.size.width - 260, g.size.width * ratio)))
                        .background(T.surface)
                        .clipShape(RoundedRectangle(cornerRadius: T.m.cardR, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: T.m.cardR, style: .continuous).stroke(T.border))
                        .overlay(alignment: .leading) { BrowserResizeHandle(ratio: $ratio, total: g.size.width) }
                }
            }
        }
    }
}

enum BrowserUI {
    /// Pages already brought into view for an agent: the browser opens beside the agent's tab for a page once;
    /// after that the user decides whether it stays open (while open, it follows the agent to its current page).
    @MainActor private static var revealed = Set<String>()

    @MainActor static func start() {
        BrowserStore.shared.restore()
        BrowserServer.shared.start()
        BrowserStore.shared.onAgentPage = { page, session in
            let store = BrowserStore.shared
            guard let tab = AppModel.shared.state.tabs.first(where: { $0.layout.sessions.contains(session) })?.id else { return }
            if revealed.insert(page.id).inserted || store.splitOpen(tab: tab) { store.show(page, in: tab) }
        }
    }

    @MainActor static func newUserPage(tab: String, url: String? = nil) {
        let p = BrowserStore.shared.newPage(owner: nil, showIn: tab)
        if let url, let u = BrowserStore.addressBarURL(url) { Task { await p.load(u) } }
        BrowserUI.focusAddress = p.id
    }

    /// The top bar's globe: shows or hides the browser beside the active tab.
    @MainActor static func toggle() {
        guard let tab = AppModel.shared.activeTabId else { return }
        let store = BrowserStore.shared
        if store.splitOpen(tab: tab) { store.closeSplit(tab: tab) } else { store.openSplit(tab: tab) }
    }

    /// The page whose address bar takes focus when it appears (a new page).
    @MainActor static var focusAddress: String?

    /// "Claude · Fix the login form"
    @MainActor static func agentLabel(_ sessionId: String) -> String {
        let m = AppModel.shared
        guard let s = m.session(sessionId) else { return "Agent" }
        let agent = m.profile(s.profileId)?.name ?? s.agentApp.map(agentAppLabel) ?? "Agent"
        let title = s.displayTitle
        return title.isEmpty || title == agent ? agent : "\(agent) · \(title)"
    }
}

/// The browser's left edge: drag to change its share of the work area.
struct BrowserResizeHandle: View {
    @Binding var ratio: Double
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 8)
            .contentShape(Rectangle())
            .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = ratio }
                    ratio = min(0.8, max(0.25, (start ?? 0.5) - Double(v.translation.width / max(total, 1))))
                }
                .onEnded { _ in start = nil })
            .offset(x: -6)
    }
}

extension BrowserUI {
    /// Opens the Web Inspector for the page (private API, as Safari's Develop menu does; harmless if it's gone).
    @MainActor static func inspect(_ page: BrowserPage) {
        let sel = NSSelectorFromString("_inspector")
        guard page.web.responds(to: sel), let inspector = page.web.perform(sel)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }
}

/// Who drives the page: live ("Claude · Fix login — Clicking “Sign in”"), or who used it last.
struct AgentBanner: View {
    @ObservedObject var page: BrowserPage

    var body: some View {
        if let a = page.activity {
            HStack(spacing: 7) {
                PulsingDot(color: NSColor(T.accent)).frame(width: 7, height: 7)
                Text(BrowserUI.agentLabel(a.sessionId)).font(T.caption.weight(.semibold)).foregroundStyle(T.text).lineLimit(1)
                Text(a.label).font(T.caption).foregroundStyle(T.text2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(T.accent.opacity(0.10))
            .transition(.opacity)
        } else if let s = page.lastAgent, let at = page.lastAgentAt {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: T.k * 10)).foregroundStyle(T.text3)
                    Text("Used by \(BrowserUI.agentLabel(s)) · \(Self.ago(at))").font(T.caption).foregroundStyle(T.text3).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 22)
            }
        }
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

struct AgentPointer: View {
    let label: String
    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .background(Image(systemName: "cursorarrow").font(.system(size: 20, weight: .black)).foregroundStyle(T.accent))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(T.accent))
                .offset(y: 14)
        }
        .fixedSize()
    }
}

struct PressRing: View {
    let seq: Int
    @State private var grow = false
    var body: some View {
        Circle().strokeBorder(T.accent, lineWidth: 2)
            .frame(width: 28, height: 28)
            .scaleEffect(grow ? 1.3 : 0.4).opacity(grow ? 0 : 0.9)
            .onAppear { animate() }
            .onChange(of: seq) { animate() }
    }
    private func animate() {
        grow = false
        withAnimation(.easeOut(duration: 0.6).delay(BrowserTools.cursorTravel)) { grow = true }
    }
}

/// Top bar: the browser beside the active tab.
struct BrowserToggleButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = BrowserStore.shared
    var body: some View {
        let open = model.activeDoc == nil && store.splitOpen(tab: model.activeTabId)
        Button { BrowserUI.toggle() } label: { Image(systemName: "globe") }
            .buttonStyle(ChromeButtonStyle(active: open)).help(open ? "Close Browser" : "Browser")
            .disabled(model.activeTabId == nil || model.activeDoc != nil)
    }
}
