import AppKit
import SwiftUI
import WebKit

/// Where a page's viewport sits in its host: laid out at a preset size (scaled down to fit, centered) or at the
/// host's size. Maps the page's CSS pixels to host points (with the page zoom), for the cursor and highlights.
struct BrowserGeometry: Equatable {
    var scale: CGFloat = 1
    var originX: CGFloat = 0
    var zoom: CGFloat = 1

    init(host: CGSize, viewport: BrowserViewport?, zoom: Double) {
        self.zoom = CGFloat(zoom)
        guard let v = viewport, host.width > 0, host.height > 0 else { return }
        scale = min(1, host.width / v.width, host.height / v.height)
        originX = max(0, (host.width - v.width * scale) / 2)
    }

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: originX + p.x * zoom * scale, y: p.y * zoom * scale) }
    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: originX + r.minX * zoom * scale, y: r.minY * zoom * scale, width: r.width * zoom * scale, height: r.height * zoom * scale)
    }
}

struct BrowserPageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var page: BrowserPage
    let tab: String
    @ObservedObject var store = BrowserStore.shared
    @ObservedObject var downloads = BrowserDownloads.shared
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var suggestions: [BrowserHistory.Entry] = []
    @State private var suggestion = -1

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 6).frame(height: 36).zIndex(2)
            ZStack(alignment: .top) {
                Hairline()
                if page.isLoading {
                    GeometryReader { g in
                        Rectangle().fill(T.accent).frame(width: max(8, g.size.width * page.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: page.progress)
                    }.frame(height: 2)
                }
            }
            if page.findVisible { BrowserFindBar(page: page) }
            AgentBanner(page: page)
            GeometryReader { g in
                let geo = BrowserGeometry(host: g.size, viewport: page.viewport, zoom: page.zoom)
                ZStack(alignment: .topLeading) {
                    BrowserWebHost(page: page)
                    AgentCursorOverlay(page: page, geo: geo)
                    PickOverlay(page: page, geo: geo)
                    if let e = page.loadError, !page.isLoading { LoadErrorView(page: page, error: e) }
                }
            }
            .overlay {
                // A soft frame while an agent drives the page (or while you pick an element).
                RoundedRectangle(cornerRadius: 2).strokeBorder(T.accent.opacity(page.activity == nil && !page.picking ? 0 : 0.55), lineWidth: 2)
                    .animation(.easeOut(duration: 0.25), value: page.activity == nil && !page.picking).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if page.picked != nil { SendElementPanel(page: page, tab: tab).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.easeOut(duration: 0.18), value: page.picked != nil)
        }
        .onAppear {
            address = page.url
            Task { await page.loadPending() }
            if BrowserUI.focusAddress == page.id { BrowserUI.focusAddress = nil; DispatchQueue.main.async { addressFocused = true } }
        }
        .onChange(of: page.url) { _, u in if !addressFocused { address = u } }
        .onChange(of: page.addressFocusRequest) { addressFocused = true }
        .onChange(of: addressFocused) { _, f in if !f { suggestions = []; suggestion = -1 } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { page.web.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(!page.canGoBack).help("Back (⌘[)")
            Button { page.web.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(!page.canGoForward).help("Forward (⌘])")
            Button { if page.isLoading { page.web.stopLoading() } else { page.web.reload() } } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 24)).help(page.isLoading ? "Stop" : "Reload (⌘R)")
            addressField
            if page.zoom != 1 {
                Button { page.zoom = 1 } label: { Text("\(Int((page.zoom * 100).rounded()))%").font(T.mono(10.5, .semibold)) }
                    .buttonStyle(ChromeButtonStyle(size: 22)).help("Actual Size (⌘0)")
            }
            if let v = page.viewport {
                Button { page.viewport = nil; if v.userAgent != nil { page.web.reload() } } label: {
                    Text(v.name).font(.system(size: T.k * 10.5, weight: .semibold))
                }
                .buttonStyle(ChromeButtonStyle(active: true, size: 22)).help("\(v.label): click to fit the browser again")
            }
            Button { page.picking ? page.stopPicking() : page.startPicking() } label: { Image(systemName: "scope") }
                .buttonStyle(ChromeButtonStyle(active: page.picking, size: 24))
                .help(page.picking ? "Stop picking (esc)" : "Pick an element to send to an agent")
            if !downloads.items.isEmpty { downloadsMenu }
            pagesMenu
            Button { BrowserUI.newUserPage(tab: tab) } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 24)).help("New Page")
            Button { store.closeSplit(tab: tab) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24)).help("Close Browser (the page stays open; the globe in the top bar brings it back)")
        }
        .font(.system(size: T.k * 12, weight: .medium))
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $address)
            .textFieldStyle(.plain).font(T.small)
            .focused($addressFocused)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.hover))
            .onChange(of: address) { _, q in
                guard addressFocused, q != page.url else { suggestions = []; return }
                suggestions = BrowserHistory.shared.suggestions(q)
                suggestion = -1
            }
            .onKeyPress(.downArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                suggestion = min(suggestions.count - 1, suggestion + 1); return .handled
            }
            .onKeyPress(.upArrow) {
                guard !suggestions.isEmpty else { return .ignored }
                suggestion = max(-1, suggestion - 1); return .handled
            }
            .onSubmit {
                let target = suggestions.indices.contains(suggestion) ? URL(string: suggestions[suggestion].url) : BrowserStore.addressBarURL(address)
                guard let u = target else { return }
                address = u.absoluteString
                suggestions = []
                addressFocused = false
                Task { await page.load(u) }
                page.web.window?.makeFirstResponder(page.web)
            }
            .onExitCommand { address = page.url; suggestions = []; addressFocused = false }
            .overlay(alignment: .topLeading) {
                if addressFocused && !suggestions.isEmpty {
                    AddressSuggestions(items: suggestions, selected: suggestion) { e in
                        guard let u = URL(string: e.url) else { return }
                        address = e.url; suggestions = []; addressFocused = false
                        Task { await page.load(u) }
                    }
                    .offset(y: 28)
                }
            }
    }

    private var downloadsMenu: some View {
        Menu {
            Section("Downloads (saved in \((BrowserDownloads.shared.folder.path as NSString).abbreviatingWithTildeInPath))") {
                ForEach(downloads.items.prefix(10)) { d in
                    if let f = d.file, d.done, d.error == nil {
                        Button("Show \(d.name) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    } else {
                        Text(d.error.map { "\(d.name): failed (\($0))" } ?? "\(d.name): downloading…")
                    }
                }
            }
            Divider()
            Button("Open Downloads Folder") { NSWorkspace.shared.open(BrowserDownloads.shared.folder) }
        } label: {
            Image(systemName: downloads.items.contains { !$0.done } ? "arrow.down.circle.dotted" : "arrow.down.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(T.text2)
        .padding(.horizontal, 4).frame(height: 24).pointerCursor()
        .help("Downloads")
    }

    private var pagesMenu: some View {
        Menu {
            Section("Pages") {
                ForEach(store.pages) { p in
                    Button {
                        store.show(p, in: tab)
                    } label: {
                        Text((p.id == page.id ? "✓ " : "") + BrowserTools.short(p.displayTitle, 50) + "  —  " + (p.owner.map(BrowserUI.agentLabel) ?? "You"))
                    }
                }
            }
            Section("Screen size") {
                Button((page.viewport == nil ? "✓ " : "") + "Fit the Browser") { setViewport(nil) }
                ForEach(BrowserViewport.presets, id: \.name) { v in
                    Button((page.viewport == v ? "✓ " : "") + v.label) { setViewport(v) }
                }
            }
            Section("Zoom") {
                Button("Zoom In (⌘+)") { page.zoomIn() }
                Button("Zoom Out (⌘−)") { page.zoomOut() }
                Button("Actual Size (⌘0)") { page.zoom = 1 }
            }
            Divider()
            Button("Find in Page (⌘F)") { page.findVisible = true }
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
        .help("Pages, screen size, zoom")
    }

    private func setViewport(_ v: BrowserViewport?) {
        let reload = page.viewport?.userAgent != v?.userAgent
        page.viewport = v
        if reload, page.web.url != nil { page.web.reload() }
    }
}

/// History matches under the address bar (↑↓ to choose, ↩ to open).
private struct AddressSuggestions: View {
    let items: [BrowserHistory.Entry]
    let selected: Int
    let open: (BrowserHistory.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.url) { i, e in
                Button { open(e) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title.isEmpty ? e.url : e.title).font(.system(size: T.k * 12, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
                        Text(e.url).font(.system(size: T.k * 10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(i == selected ? T.selection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.raised).shadow(color: .black.opacity(0.25), radius: 8, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border))
    }
}

/// ⌘F: find in the page, with the number of matches.
struct BrowserFindBar: View {
    @ObservedObject var page: BrowserPage
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(T.text3)
            TextField("Find in page", text: $text)
                .textFieldStyle(.plain).font(T.small).focused($focused)
                .onChange(of: text) { _, t in page.find(t) }
                .onKeyPress(.return, phases: .down) { k in page.find(text, backwards: k.modifiers.contains(.shift)); return .handled }
                .onExitCommand { close() }
            if let n = page.findCount, !text.isEmpty {
                Text(n == 0 ? "No matches" : n == 1 ? "1 match" : "\(n) matches").font(T.caption).foregroundStyle(n == 0 ? T.red : T.text3)
            }
            Button { page.find(text, backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(IconButtonStyle(size: 22)).help("Previous (⇧↩)").disabled(text.isEmpty)
            Button { page.find(text) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(IconButtonStyle(size: 22)).help("Next (↩)").disabled(text.isEmpty)
            Button("Done") { close() }.buttonStyle(ChromeButtonStyle(size: 22)).font(T.caption)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(T.hover.opacity(0.5))
        .onAppear { focused = true }
    }

    private func close() {
        page.findVisible = false
        page.findCount = nil
        page.web.window?.makeFirstResponder(page.web)
    }
}

/// A page that couldn't be loaded: what went wrong and Try Again.
private struct LoadErrorView: View {
    @ObservedObject var page: BrowserPage
    let error: (url: URL?, message: String)

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: T.k * 26, weight: .light)).foregroundStyle(T.text3)
            Text("Couldn't open \(error.url?.host ?? error.url?.absoluteString ?? "the page")").font(T.headline).foregroundStyle(T.text)
            Text(error.message).font(T.body).foregroundStyle(T.text2).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let u = error.url { Text(u.absoluteString).font(T.mono(11)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.middle).frame(maxWidth: 360) }
            HStack(spacing: 8) {
                Button("Try Again") { if let u = error.url { Task { await page.load(u) } } else { page.web.reload() } }
                    .buttonStyle(PrimaryButtonStyle())
                if let u = error.url { Button("Open in Default Browser") { NSWorkspace.shared.open(u) }.buttonStyle(SecondaryButtonStyle()) }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.surface)
    }
}

/// The agent's pointer: glides to where the action lands, rings on arrival, and frames the element.
struct AgentCursorOverlay: View {
    @ObservedObject var page: BrowserPage
    let geo: BrowserGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let a = page.activity {
                if let box = a.box.map(geo.rect) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(T.accent, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.accent.opacity(0.08)))
                        .frame(width: max(box.width + 6, 8), height: max(box.height + 6, 8))
                        .offset(x: box.minX - 3, y: box.minY - 3)
                        .transition(.opacity)
                }
                if let p = a.point.map(geo.point) {
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

/// While picking: the element under the pointer, framed and named.
private struct PickOverlay: View {
    @ObservedObject var page: BrowserPage
    let geo: BrowserGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            if page.picking {
                if let h = page.pickHover {
                    let r = geo.rect(h.box)
                    RoundedRectangle(cornerRadius: 3).stroke(T.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(RoundedRectangle(cornerRadius: 3).fill(T.accent.opacity(0.10)))
                        .frame(width: max(r.width, 4), height: max(r.height, 4)).offset(x: r.minX, y: r.minY)
                    Text(h.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(T.accent))
                        .fixedSize().offset(x: r.minX, y: max(0, r.minY - 20))
                } else {
                    Text("Click an element to send it to an agent · esc to stop").font(T.caption).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(T.accent.opacity(0.9)))
                        .frame(maxWidth: .infinity).padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Hosts the page's own WKWebView (pages keep running, and agents keep using them, when not on screen).
struct BrowserWebHost: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> BrowserHostView {
        let v = BrowserHostView()
        v.page = page
        v.attach()
        return v
    }

    func updateNSView(_ v: BrowserHostView, context: Context) {
        v.page = page
        if page.web.superview !== v { v.attach() }
        v.needsLayout = true
    }

    static func dismantleNSView(_ v: BrowserHostView, coordinator: ()) {
        // Off screen the page keeps its size, so an agent's snapshots and screenshots stay the same. SwiftUI can
        // build a host and drop it while another one shows the same page: that one takes the page back.
        guard let page = v.page, page.web.superview === v else { return }
        page.web.removeFromSuperview()
        BrowserHostView.live.allObjects.first { $0 !== v && $0.page === page && $0.window != nil }?.attach()
    }
}

/// Lays the web view out at the page's screen size (scaled to fit) or its own size, and takes the browser's
/// shortcuts while the page has the keyboard (so they never reach a terminal's).
final class BrowserHostView: NSView {
    weak var page: BrowserPage?
    override var isFlipped: Bool { true }
    static let live = NSHashTable<BrowserHostView>.weakObjects()

    override init(frame: NSRect) { super.init(frame: frame); Self.live.add(self) }
    required init?(coder: NSCoder) { super.init(coder: coder); Self.live.add(self) }

    /// On screen without its page (another host had it): take it back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let web = page?.web, web.superview == nil { attach() }
    }

    func attach() {
        guard let web = page?.web else { return }
        subviews.filter { $0 !== web }.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.autoresizingMask = []
        addSubview(web)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let page else { return }
        if page.web.superview == nil, window != nil { attach(); return }
        guard page.web.superview === self else { return }
        let size = frame.size
        guard let v = page.viewport else {
            setBoundsSize(size)
            page.web.frame = NSRect(origin: .zero, size: size)
            return
        }
        let g = BrowserGeometry(host: size, viewport: v, zoom: 1)
        setBoundsSize(NSSize(width: size.width / g.scale, height: size.height / g.scale))
        page.web.frame = NSRect(x: g.originX / g.scale, y: 0, width: v.width, height: v.height)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let page, let fr = window?.firstResponder as? NSView, fr === self || fr.isDescendant(of: self),
              let action = BrowserKeys.action(for: event) else { return super.performKeyEquivalent(with: event) }
        BrowserKeys.perform(action, on: page)
        return true
    }
}

/// The browser's own shortcuts (only while a page has the keyboard).
enum BrowserKeys {
    enum Action: Equatable { case find, address, back, forward, reload, zoomIn, zoomOut, zoomReset }

    static func action(for e: NSEvent) -> Action? {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        return action(chars: e.charactersIgnoringModifiers ?? "", command: mods.contains(.command), others: mods.subtracting([.command, .shift]))
    }

    static func action(chars: String, command: Bool, others: NSEvent.ModifierFlags = []) -> Action? {
        guard command, others.isEmpty else { return nil }
        switch chars.lowercased() {
        case "f": return .find
        case "l": return .address
        case "[": return .back
        case "]": return .forward
        case "r": return .reload
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "0": return .zoomReset
        default: return nil
        }
    }

    @MainActor static func perform(_ a: Action, on page: BrowserPage) {
        switch a {
        case .find: page.findVisible = true
        case .address: page.addressFocusRequest += 1
        case .back: page.web.goBack()
        case .forward: page.web.goForward()
        case .reload: page.web.reload()
        case .zoomIn: page.zoomIn()
        case .zoomOut: page.zoomOut()
        case .zoomReset: page.zoom = 1
        }
    }
}
