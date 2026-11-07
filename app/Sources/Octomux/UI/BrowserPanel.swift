import AppKit
import SwiftUI
import WebKit

/// The right panel's Browser tab: the Octomux browser's pages, which agents drive through their browser tools
/// while the user watches (cursor, action label, highlighted element) or takes over.
struct BrowserPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = BrowserStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if let page = store.shownPage {
                BrowserPageView(page: page).id(page.id)
            } else {
                VStack(spacing: 10) {
                    PanelEmpty(icon: "globe", text: "No pages open").frame(height: 90)
                    Text("Agents open pages here when they use the browser, and you can watch them work.")
                        .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center).frame(maxWidth: 260)
                    Button { BrowserUI.newUserPage() } label: { Label("New Page", systemImage: "plus") }
                        .buttonStyle(ChromeButtonStyle()).font(T.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.focusedSessionId) { _, id in
            // Following the user around: the page the newly focused session works in.
            if let id, let p = store.currentPage(of: id) { store.shownPageId = p.id }
        }
    }
}

enum BrowserUI {
    /// Pages already brought into view for an agent (the panel opens for an agent's page once; after that the
    /// user decides whether it stays open).
    @MainActor private static var revealed = Set<String>()

    @MainActor static func start() {
        BrowserStore.shared.restore()
        BrowserServer.shared.start()
        BrowserStore.shared.onAgentPage = { page, session in
            let m = AppModel.shared
            let inView = m.focusedSessionId == session || (m.activeDoc == nil && m.activeTab?.layout.sessions.contains(session) == true)
            guard inView else { return }
            BrowserStore.shared.shownPageId = page.id
            if revealed.insert(page.id).inserted {
                UserDefaults.standard.set(RightTab.browser.rawValue, forKey: "octomux.rightTab")
                m.setRightPanel(true)
            }
        }
    }

    @MainActor static func newUserPage(url: String? = nil) {
        let p = BrowserStore.shared.newPage(owner: nil, show: true)
        if let url, let u = BrowserStore.addressBarURL(url) { Task { await p.load(u) } }
        BrowserUI.focusAddress = p.id
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

struct BrowserPageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var page: BrowserPage
    @ObservedObject var store = BrowserStore.shared
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 6).frame(height: 36)
            ZStack(alignment: .top) {
                Hairline()
                if page.isLoading {
                    GeometryReader { g in
                        Rectangle().fill(T.accent).frame(width: max(8, g.size.width * page.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: page.progress)
                    }.frame(height: 2)
                }
            }
            AgentBanner(page: page)
            ZStack(alignment: .topLeading) {
                BrowserWebHost(page: page)
                AgentCursorOverlay(page: page)
            }
            .overlay {
                // A soft frame while an agent drives the page.
                RoundedRectangle(cornerRadius: 2).strokeBorder(T.accent.opacity(page.activity == nil ? 0 : 0.55), lineWidth: 2)
                    .animation(.easeOut(duration: 0.25), value: page.activity == nil).allowsHitTesting(false)
            }
        }
        .onAppear {
            address = page.url
            Task { await page.loadPending() }
            if BrowserUI.focusAddress == page.id { BrowserUI.focusAddress = nil; DispatchQueue.main.async { addressFocused = true } }
        }
        .onChange(of: page.url) { _, u in if !addressFocused { address = u } }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { page.web.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(!page.canGoBack).help("Back")
            Button { page.web.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(!page.canGoForward).help("Forward")
            Button { if page.isLoading { page.web.stopLoading() } else { page.web.reload() } } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 24)).help(page.isLoading ? "Stop" : "Reload")
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain).font(T.small)
                .focused($addressFocused)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
                .onSubmit {
                    guard let u = BrowserStore.addressBarURL(address) else { return }
                    addressFocused = false
                    Task { await page.load(u) }
                }
                .onExitCommand { address = page.url; addressFocused = false }
            pagesMenu
            Button { BrowserUI.newUserPage() } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 24)).help("New Page")
        }
        .font(.system(size: T.k * 12, weight: .medium))
    }

    private var pagesMenu: some View {
        Menu {
            Section("Pages") {
                ForEach(store.pages) { p in
                    Button {
                        store.shownPageId = p.id
                    } label: {
                        Text((p.id == page.id ? "✓ " : "") + BrowserTools.short(p.displayTitle, 50) + "  —  " + (p.owner.map(BrowserUI.agentLabel) ?? "You"))
                    }
                }
            }
            Divider()
            Button("Open in Default Browser") { if let u = page.web.url { NSWorkspace.shared.open(u) } }.disabled(page.web.url == nil)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.url, forType: .string)
            }
            Button("Web Inspector") { BrowserUI.inspect(page) }
            Divider()
            Button("Close Page") { store.close(page.id) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.on.square")
                if store.pages.count > 1 { Text("\(store.pages.count)").font(T.mono(10, .semibold)) }
            }
            .foregroundStyle(T.text2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(T.text2)
        .padding(.horizontal, 4).frame(height: 24)
        .pointerCursor()
        .help("Pages")
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
    @State private var pulse = false

    var body: some View {
        if let a = page.activity {
            HStack(spacing: 7) {
                Circle().fill(T.accent).frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.25 : 0.85).opacity(pulse ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
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

/// The agent's pointer: glides to where the action lands, rings on arrival, and frames the element.
struct AgentCursorOverlay: View {
    @ObservedObject var page: BrowserPage

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let a = page.activity {
                if let box = a.box {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(T.accent, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.accent.opacity(0.08)))
                        .frame(width: max(box.width + 6, 8), height: max(box.height + 6, 8))
                        .offset(x: box.minX - 3, y: box.minY - 3)
                        .transition(.opacity)
                }
                if let p = a.point {
                    PressRing(seq: a.seq).offset(x: p.x - 14, y: p.y - 14)
                    AgentPointer(label: BrowserUI.agentLabel(a.sessionId).components(separatedBy: " · ").first ?? "Agent")
                        .offset(x: p.x - 3, y: p.y - 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: BrowserTools.cursorTravel, dampingFraction: 0.82), value: page.activity?.point)
        .animation(.easeOut(duration: 0.2), value: page.activity?.box)
        .allowsHitTesting(false)
    }
}

private struct AgentPointer: View {
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

private struct PressRing: View {
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

/// Hosts the page's own WKWebView (pages keep running, and agents keep using them, when not on screen).
struct BrowserWebHost: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        attach(page.web, to: v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if page.web.superview !== v { attach(page.web, to: v) }
    }

    private func attach(_ web: WKWebView, to v: NSView) {
        v.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.frame = v.bounds
        web.autoresizingMask = [.width, .height]
        v.addSubview(web)
    }

    static func dismantleNSView(_ v: NSView, coordinator: ()) {
        // Off screen the page keeps its size, so an agent's snapshots and screenshots stay the same.
        v.subviews.forEach { $0.removeFromSuperview() }
    }
}
