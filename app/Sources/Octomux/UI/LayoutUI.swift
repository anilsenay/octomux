import AppKit
import SwiftUI

/// The status bar's Layout button (off in Terminal's status bar, on in the others): the layout in use; its panel
/// switches layouts.
struct LayoutControl: View {
    @EnvironmentObject var model: AppModel
    var full = true
    @State private var open = false

    var body: some View {
        let p = model.layout.preset
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: p.icon).font(.system(size: T.k * 11))
                if full { Text(p.title) }
            }
        }
        .buttonStyle(ChromeButtonStyle(active: open))
        .fixedSize()
        .help("Layout: \(p.title) (⌃⌘1…4)")
        .floatingPanel(isPresented: $open, edge: .top, alignment: .trailing) { LayoutPanel() }
        .debugOpens("layout", $open)
    }
}

/// The layouts, the one in use checked; Customize opens Settings → Layout.
struct LayoutPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav = PanelNav()

    var body: some View {
        let current = model.layout.preset
        let presets = LayoutPreset.allCases
        let actions: [() -> Void] = presets.map { p in { model.chooseLayout(p) } } + [{ SettingsWindow.show(section: .layout) }]
        PanelCard(width: 300) {
            PanelSectionTitle("Layout")
            ForEach(Array(presets.enumerated()), id: \.element) { i, p in
                row(i, PanelRow(title: p.title, shortcut: "⌃⌘\(p.number)", checked: p == current, highlighted: nav.index == i) {
                    Image(systemName: p.icon).font(T.icon(11)).foregroundStyle(T.text3)
                })
                .help(p.summary)
            }
            PanelDivider()
            row(presets.count, PanelRow(title: "Customize Layout…", highlighted: nav.index == presets.count) {
                Image(systemName: "slider.horizontal.3").font(T.icon(11)).foregroundStyle(T.text3)
            })
        }
        .onAppear { nav.set(actions); nav.attach() }
    }

    private func row<V: View>(_ i: Int, _ v: V) -> some View {
        v.onHover { h in if h { nav.index = i } else if nav.index == i { nav.index = nil } }
            .onTapGesture { nav.run(i) }
            .panelPointer()
    }
}

/// Drag the right panel's left edge: left makes it wider.
struct RightPanelResizeHandle: View {
    @EnvironmentObject var model: AppModel
    @State private var start: CGFloat?

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 6)
            .contentShape(Rectangle())
            .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = model.rightPanelWidth }
                    let r = AppModel.rightPanelWidths
                    model.rightPanelWidth = min(r.upperBound, max(r.lowerBound, (start ?? AppModel.rightPanelDefaultWidth) - v.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: -3)
            .help("Drag to resize")
    }
}

// MARK: - Settings → Layout

struct LayoutSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var message: String?

    var body: some View {
        let c = model.layout
        let customized = LayoutEdit.isCustomized(model.layoutStored)
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Layout", desc: "One layout for the whole app. Each keeps its own changes below; switch with ⌃⌘1…4, the command palette, or the Layout button in the status bar.") {
                HStack(spacing: 10) {
                    ForEach(LayoutPreset.allCases) { p in card(p, on: p == c.preset) }
                }
                .padding(12)
            }
            SettingsGroup("\(c.preset.title) layout", desc: customized ? "Changed from how it comes." : "As it comes.", trailing: {
                HStack(spacing: 8) {
                    if let message { Text(message).font(.system(size: T.k * 12)).foregroundStyle(T.text2) }
                    Button("Export…", action: export)
                    Button("Import…", action: importFile)
                    Button("Reset to \(c.preset.title)") { model.editLayout { LayoutEdit.reset(stored: $0) } }.disabled(!customized)
                }
                .controlSize(.small)
            }) {
                SettingRow("Status bar", desc: "The bar at the bottom of the window.") {
                    SettingSwitch(isOn: Binding(get: { c.statusBar }, set: { v in model.editLayout { LayoutEdit.flag("statusBar", v, stored: $0) } }))
                }
                SettingRow("Open new agents as chats", desc: "New Claude and Codex sessions start in the chat view (⌘⇧C switches any session).") {
                    SettingSwitch(isOn: Binding(get: { c.chat }, set: { v in model.editLayout { LayoutEdit.flag("chat", v, stored: $0) } }))
                }
                SettingRow("Agent beside the work area", desc: "The project's agent in a column on the left: its chat next to the files you open.") {
                    SettingSwitch(isOn: Binding(get: { c.sideChat }, set: { v in model.editLayout { LayoutEdit.flag("sideChat", v, stored: $0) } }))
                }
            }
            ForEach(LayoutRegion.allCases) { r in region(r, c) }
        }
    }

    private func card(_ p: LayoutPreset, on: Bool) -> some View {
        Button { model.chooseLayout(p) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: p.icon).font(T.icon(13)).foregroundStyle(on ? T.accent : T.text2)
                    Spacer()
                    Text("⌃⌘\(p.number)").font(T.meta).foregroundStyle(T.text3)
                }
                Text(p.title).font(.system(size: T.k * 13, weight: .semibold)).foregroundStyle(T.text)
                Text(p.summary).font(.system(size: T.k * 11)).foregroundStyle(T.text2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: R.lg, style: .continuous).fill(on ? T.selection : T.hover))
            .overlay(RoundedRectangle(cornerRadius: R.lg, style: .continuous).stroke(on ? T.accent.opacity(0.6) : T.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func region(_ r: LayoutRegion, _ c: LayoutConfig) -> some View {
        let items = c.items(r)
        return SettingsGroup(r.title, desc: r.desc) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        arrow("chevron.up", enabled: i > 0) { model.editLayout { LayoutEdit.move(it.id, in: r, by: -1, stored: $0) } }
                        arrow("chevron.down", enabled: i < items.count - 1) { model.editLayout { LayoutEdit.move(it.id, in: r, by: 1, stored: $0) } }
                    }
                    Text(LayoutRegion.itemTitle(it.id, in: r)).font(.system(size: T.k * 13)).foregroundStyle(it.on ? T.text : T.text3)
                    Spacer()
                    SettingSwitch(isOn: Binding(get: { it.on }, set: { v in model.editLayout { LayoutEdit.toggle(it.id, in: r, on: v, stored: $0) } }))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(T.icon(9, .bold)).frame(width: 18, height: 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? T.text2 : T.text3.opacity(0.4)).disabled(!enabled)
        .help(symbol == "chevron.up" ? "Move up" : "Move down")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Octomux Layout.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LayoutEdit.exporting(model.layoutStored).write(to: url); message = "Saved." }
        catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = Self.importLayout(from: url, model: model)
    }

    /// Reads a layout file into the app; the message to show.
    static func importLayout(from url: URL, model: AppModel) -> String {
        guard let data = try? Data(contentsOf: url), let v = LayoutEdit.importing(data) else { return "Not an Octomux layout file." }
        model.storeLayout(v)
        let p = LayoutConfig.resolve(v).preset
        model.chooseLayout(p)
        return "Imported."
    }
}
