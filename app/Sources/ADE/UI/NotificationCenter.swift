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
            Image(systemName: count > 0 ? "bell.badge" : "bell").font(.system(size: 12.5))
                .symbolRenderingMode(count > 0 ? .palette : .monochrome)
                .foregroundStyle(count > 0 ? T.amber : T.text2, T.text2)
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 8.5, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5).frame(minWidth: 13, minHeight: 13)
                    .background(Capsule().fill(T.amber))
                    .offset(x: 3, y: -1)
                    .allowsHitTesting(false)
            }
        }
        .help(count > 0 ? "\(count) unread notifications" : "Notifications")
        .background(DropdownAnchor(isPresented: $open) { NotificationList { open = false } })
        .onChange(of: open) { _, v in if v { center.refreshAll() } }
        .onReceive(NotificationCenter.default.publisher(for: .adeDebugPanel)) { n in
            if let v = n.userInfo?["notifications"] as? Bool { open = v }
        }
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
            if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil) }
            panel = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.close() }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        if isPresented, c.panel == nil, let win = v.window {
            let host = NSHostingView(rootView: AnyView(content()
                .background(T.m.glass ? AnyView(VisualEffect(material: .popover)) : AnyView(T.raised))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border))
                .foregroundStyle(T.text)
                .environmentObject(AppModel.shared)))
            let size = host.fittingSize
            let anchor = v.convert(v.bounds, to: nil)
            let origin = win.convertPoint(toScreen: NSPoint(x: anchor.minX - 4, y: anchor.minY - 6 - size.height))
            let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = host
            host.sizingOptions = [.intrinsicContentSize]
            win.addChildWindow(p, ordered: .above)
            p.orderFront(nil)
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
        } else if isPresented, let p = c.panel, let win = v.window, let host = p.contentView {
            // Content grew or shrank (items arrived): keep the top edge under the anchor.
            let size = host.fittingSize
            let anchor = v.convert(v.bounds, to: nil)
            let origin = win.convertPoint(toScreen: NSPoint(x: anchor.minX - 4, y: anchor.minY - 6 - size.height))
            p.setFrame(NSRect(origin: origin, size: size), display: true)
        } else if !isPresented, c.panel != nil {
            c.close()
        }
    }
}
