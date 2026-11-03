import SwiftUI

/// Notification center: what agents and programs reported (finished, needs input, errors, long
/// commands), kept by each daemon so it survives restarts. Merged across hosts, newest first.
final class NotificationCenterModel: ObservableObject {
    static let shared = NotificationCenterModel()

    struct Item: Identifiable {
        let client: DaemonClient
        var n: AppNotification
        var id: String { "\(ObjectIdentifier(client).hashValue):\(n.id ?? 0)" }
        var read: Bool { n.read ?? false }
        var date: Date { Date(timeIntervalSince1970: TimeInterval(n.ts ?? 0)) }
    }

    @Published private(set) var items: [Item] = []
    private var loaded = Set<ObjectIdentifier>()

    var unread: [Item] { items.filter { !$0.read } }
    var unreadCount: Int { items.reduce(0) { $0 + ($1.read ? 0 : 1) } }

    func ensureLoaded(_ c: DaemonClient) {
        guard !loaded.contains(ObjectIdentifier(c)) else { return }
        loaded.insert(ObjectIdentifier(c))
        refresh(c)
    }

    func refreshAll() {
        let m = AppModel.shared
        refresh(m.client)
        for c in m.extraClients.values { refresh(c) }
    }

    func refresh(_ c: DaemonClient) {
        c.call("notifications.list", ["limit": 200]) { [weak self] r in
            guard case .success(let v) = r, let arr = (v as? [String: Any])?["notifications"],
                  let data = try? JSONSerialization.data(withJSONObject: arr),
                  let list = try? JSONDecoder().decode([AppNotification].self, from: data) else { return }
            DispatchQueue.main.async { self?.replace(list.map { Item(client: c, n: $0) }, for: c) }
        }
    }

    private func replace(_ new: [Item], for c: DaemonClient) {
        items = (items.filter { $0.client !== c } + new).sorted { ($0.n.ts ?? 0, $0.n.id ?? 0) > ($1.n.ts ?? 0, $1.n.id ?? 0) }
    }

    /// A live `notify` event. When the user is already looking at that session, it lands as read.
    func received(_ n: AppNotification, from c: DaemonClient) {
        guard n.id != nil else { return }   // daemon without a notification store
        var n = n
        let m = AppModel.shared
        if NSApp.isActive, m.activeDoc == nil, m.focusedSessionId == n.sessionId {
            n.read = true
            c.call("notifications.read", ["ids": [n.id!]])
        }
        items.removeAll { $0.client === c && $0.n.id == n.id }
        items.insert(Item(client: c, n: n), at: 0)
    }

    func open(_ item: Item) {
        let m = AppModel.shared
        if m.session(item.n.sessionId) != nil { m.selectSession(item.n.sessionId) }
        markRead(item)
    }

    func markRead(_ item: Item) {
        guard !item.read, let id = item.n.id else { return }
        item.client.call("notifications.read", ["ids": [id]])
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].n.read = true }
    }

    func markAllRead() {
        for c in clients { c.call("notifications.read", [:]) }
        for i in items.indices { items[i].n.read = true }
    }

    func clearAll() {
        for c in clients { c.call("notifications.clear", [:]) }
        items = []
    }

    /// Opens the newest unread one (the bell's "Next unread").
    func openNextUnread() {
        if let first = unread.first { open(first) }
    }

    private var clients: [DaemonClient] {
        var seen = Set<ObjectIdentifier>()
        return items.map(\.client).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

/// Top-left bell with the unread count; opens the notification list.
struct NotificationBell: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center = NotificationCenterModel.shared
    @State private var open = false

    var body: some View {
        let count = center.unreadCount
        Button { open.toggle() } label: {
            // Plain bell: `bell.badge` drew its own dot under our count badge.
            Image(systemName: "bell").font(.system(size: 12.5)).foregroundStyle(T.text2)
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 8.5, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Self.badgeInk(model.workspace?.color))
                    .padding(.horizontal, 3.5).frame(minWidth: 13, minHeight: 13)
                    .background(Capsule().fill(Self.badgeFill(model.workspace?.color)))
                    .offset(x: -1, y: 2)
                    .allowsHitTesting(false)
            }
        }
        .help(count > 0 ? "\(count) unread notifications" : "Notifications")
        .background(DropdownAnchor(isPresented: $open) { NotificationList { open = false } })
        .onChange(of: open) { _, v in if v { center.refreshAll() } }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["notifications"] as? Bool { open = v }
        }
        .onReceive(NotificationCenter.default.publisher(for: .octomuxShowNotifications)) { _ in open = true }
    }
}

extension Notification.Name {
    /// Opens the bell's list (the menu bar panel's "All recent").
    static let octomuxShowNotifications = Notification.Name("octomux.showNotifications")
}

/// The menu bar icon's panel: unread notifications (or, with none, the agents that are working or waiting), each with
/// its workspace › project, a spinner while that agent works; "All recent" opens the app's list. Shown in its own
/// borderless panel under the icon (StatusItemController), opaque and in the app's colors.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center = NotificationCenterModel.shared
    let close: () -> Void

    private struct Row: Identifiable {
        let id: String
        let title: String
        let dot: Color?
        let session: Session?
        let projectId: String
        let date: Date?
        let open: () -> Void
    }

    private var rows: [Row] {
        let unread = center.unread.prefix(6).map { item -> Row in
            let s = model.session(item.n.sessionId)
            return Row(id: "n" + item.id, title: s?.displayTitle ?? item.n.title, dot: NotificationRow.color(item.n.kind), session: s,
                       projectId: item.n.projectId, date: item.date) { center.open(item) }
        }
        if !unread.isEmpty { return unread }
        return model.state.sessions.filter { $0.isAgent && !$0.isDormant && ($0.activity == .working || $0.activity == .needsInput) }
            .prefix(6).map { s in
                Row(id: "s" + s.id, title: s.displayTitle, dot: s.activity == .needsInput ? T.amber : nil, session: s,
                    projectId: s.projectId, date: nil) { model.selectSession(s.id) }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let list = rows
            if list.isEmpty {
                Text("No new notifications").font(.system(size: 12.5)).foregroundStyle(T.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                VStack(spacing: 2) {
                    ForEach(list) { r in row(r) }
                }
                .padding(6)
            }
            Hairline().padding(.horizontal, 12)
            Button { show { NotificationCenter.default.post(name: .octomuxShowNotifications, object: nil) } } label: {
                HStack {
                    Text("All recent").font(.system(size: 12.5)).foregroundStyle(T.text2)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
                }
                .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverHighlight(radius: 6).padding(6)
        }
        .frame(width: 340)
        // Opaque, in the app's colors: a translucent panel took the menu bar's / wallpaper's tint.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.border))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }

    private func row(_ r: Row) -> some View {
        let project = model.project(r.projectId)
        let ws = project.flatMap { p in model.state.workspaces.first { $0.id == p.workspaceId } }
        return Button { show(r.open) } label: {
            HStack(spacing: 9) {
                Circle().fill(r.dot ?? .clear).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(T.text).lineLimit(1)
                    HStack(spacing: 4) {
                        if let ws {
                            Circle().fill(Color(hex: ws.color)).frame(width: 6, height: 6)
                            Text(ws.name)
                            if project != nil { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)) }
                        }
                        if let project { Text(project.name) }
                    }
                    .font(.system(size: 11)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if r.session?.activity == .working && r.session?.state == .running { WorkingRing(size: 12) }
                else if let d = r.date { Text(NotificationRow.when(d)).font(.system(size: 10.5)).foregroundStyle(T.text3).monospacedDigit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(radius: 7)
    }

    /// Brings the window forward (switching to the row's workspace happens in selectSession), then acts.
    private func show(_ then: @escaping () -> Void) {
        close()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.delegate as? AppDelegate)?.openMainWindow()
        DispatchQueue.main.async(execute: then)
    }
}

extension NotificationBell {
    /// The count badge takes the workspace's color (the dot in the workspace picker); gray or none → the accent.
    static func badgeFill(_ hex: String?) -> Color {
        guard let hex, let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB), c.saturationComponent > 0.12 else { return T.accent }
        return Color(nsColor: c)
    }
    /// White on dark or saturated colors, near-black on light ones (yellow, lime).
    static func badgeInk(_ hex: String?) -> Color {
        guard let hex, let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB), c.saturationComponent > 0.12 else { return .white }
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l > 0.62 ? Color(white: 0.1) : .white
    }
}

struct NotificationList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center = NotificationCenterModel.shared
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Notifications").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                Spacer(minLength: 12)
                toolbarButton("Next unread", "chevron.right", disabled: center.unreadCount == 0) {
                    center.openNextUnread(); close()
                }
                toolbarButton("Mark all read", "checkmark", disabled: center.unreadCount == 0) { center.markAllRead() }
                toolbarButton("Clear all", "xmark", disabled: center.items.isEmpty) { center.clearAll() }
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 40)
            Hairline()
            if center.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash").font(.system(size: 20)).foregroundStyle(T.text3)
                    Text("No notifications").font(T.body).foregroundStyle(T.text2)
                    Text("Agents finishing, asking for input or failing show up here.")
                        .font(T.caption).foregroundStyle(T.text3).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let unread = center.items.filter { !$0.read }, read = center.items.filter(\.read)
                        if !unread.isEmpty { section("Unread", unread) }
                        if !read.isEmpty { section("Read", read) }
                    }
                    .padding(8)
                }
                .frame(height: min(460, CGFloat(center.items.count) * 66 + 60))
            }
        }
        .frame(width: 430)
    }

    private func toolbarButton(_ title: String, _ icon: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
            }
            .foregroundStyle(disabled ? T.text3.opacity(0.6) : T.text2)
            .padding(.horizontal, 7).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .hoverHighlight(radius: 5)
    }

    @ViewBuilder private func section(_ title: String, _ list: [NotificationCenterModel.Item]) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(T.text3)
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
        ForEach(list) { item in
            NotificationRow(item: item) { center.open(item); close() }
        }
    }
}

struct NotificationRow: View {
    @EnvironmentObject var model: AppModel
    let item: NotificationCenterModel.Item
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let n = item.n
        let session = model.session(n.sessionId)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.hover)
                if let session { AgentIcon(icon: iconName(for: session, model: model), size: 14) }
                else { Image(systemName: "bell").font(.system(size: 12)).foregroundStyle(T.text3) }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !item.read { Circle().fill(Self.color(n.kind)).frame(width: 6, height: 6) }
                    Text(session?.displayTitle ?? n.title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(item.read ? T.text2 : T.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.when(item.date)).font(.system(size: 10.5)).foregroundStyle(T.text3).monospacedDigit()
                }
                Text(Self.message(n, hasSession: session != nil)).font(.system(size: 12)).foregroundStyle(T.text2).lineLimit(2)
                Text([model.project(n.projectId)?.name, Self.status(n.kind), session == nil ? "closed" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(T.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? T.hover : item.read ? .clear : T.hover.opacity(0.45)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pointerCursor()
        .onTapGesture(perform: open)
        .help(session == nil ? "This session was closed" : "Go to this session")
    }

    /// The headline is the session; this line says what happened.
    static func message(_ n: AppNotification, hasSession: Bool) -> String {
        switch n.kind {
        case "done": return "Finished a turn"
        case "needs_input": return "Needs your input"
        case "error": return "Hit an error"
        case "command_done": return [n.title, n.body.components(separatedBy: " · ").last].compactMap { $0 }.joined(separator: " · ")
        default: return n.body.isEmpty ? n.title : (hasSession ? n.title + ": " + n.body : n.body)
        }
    }

    static func status(_ kind: String) -> String {
        switch kind {
        case "done": return "Finished"
        case "needs_input": return "Needs input"
        case "error": return "Error"
        case "command_done": return "Command"
        default: return "Message"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "needs_input": return T.amber
        case "error": return T.red
        case "done": return T.green
        default: return T.accent
        }
    }

    static func when(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }
}

/// A dropdown below its anchor, left edges aligned (an NSPopover centers on the anchor and would hang off
/// the window's left side here). A borderless child window, so it draws over the terminals' Metal views.
/// Closes on a click outside, Esc, or when the app goes to the background.
struct DropdownAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    final class Coordinator {
        var panel: NSPanel?
        var monitors: [Any] = []
        var observer: Any?
        func close() {
            monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            if let p = panel {
                let parent = p.parent
                parent?.removeChildWindow(p); p.orderOut(nil)
                parent?.makeKey()   // typing goes back to the window (composer, terminal)
            }
            panel = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.close() }

    /// Borderless panels cannot become key by default; this one must, for search and name fields.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Reports content size changes (rows loading, a field appearing) so the panel can follow.
    final class Host: NSHostingView<AnyView> {
        var onResize: (() -> Void)?
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onResize?() }
        }
    }

    private static func place(_ p: NSPanel, host: NSView, anchor v: NSView) {
        guard let win = v.window else { return }
        let size = host.fittingSize
        let a = v.convert(v.bounds, to: nil)
        var origin = win.convertPoint(toScreen: NSPoint(x: a.minX - 4, y: a.minY - 6 - size.height))
        // No room below (composer at the window's bottom): open above the anchor instead.
        let floor = max(win.frame.minY, win.screen?.visibleFrame.minY ?? 0) + 4
        if origin.y < floor { origin = win.convertPoint(toScreen: NSPoint(x: a.minX - 4, y: a.maxY + 6)) }
        let frame = NSRect(origin: origin, size: size)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        if isPresented, c.panel == nil, let win = v.window {
            let host = Host(rootView: AnyView(content()
                .background(T.m.glass ? AnyView(VisualEffect(material: .popover)) : AnyView(T.raised))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border))
                .foregroundStyle(T.text)
                .environmentObject(AppModel.shared)))
            let p = Panel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.contentView = host
            host.sizingOptions = [.intrinsicContentSize]
            host.onResize = { [weak p, weak host, weak v] in
                if let p, let host, let v { Self.place(p, host: host, anchor: v) }
            }
            Self.place(p, host: host, anchor: v)
            win.addChildWindow(p, ordered: .above)
            p.makeKeyAndOrderFront(nil)
            c.panel = p
            let dismiss = { DispatchQueue.main.async { isPresented = false } }
            c.monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                if e.window !== p, !(e.window === win && v.convert(v.bounds, to: nil).contains(e.locationInWindow)) { dismiss() }
                return e
            } as Any)
            c.monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == 53 { dismiss(); return nil }
                return e
            } as Any)
            c.observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in dismiss() }
        } else if isPresented, let p = c.panel, let host = p.contentView {
            Self.place(p, host: host, anchor: v)
        } else if !isPresented, c.panel != nil {
            c.close()
        }
    }
}
