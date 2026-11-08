import AppKit
import SwiftUI

/// The status bar's Layout button (off in Terminal's status bar, on in the others): the layout in use; its panel
/// switches layouts.
struct LayoutControl: View {
    @EnvironmentObject var model: AppModel
    var full = true
    @State private var open = false

    var body: some View {
        let c = model.layout
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: c.preset.icon).font(.system(size: T.k * 11))
                if full { Text(c.title) }
            }
        }
        .buttonStyle(ChromeButtonStyle(active: open))
        .fixedSize()
        .help("Layout: \(c.title) (⌃⌘1…\(LayoutPreset.allCases.count))")
        .floatingPanel(isPresented: $open, edge: .top, alignment: .trailing) { LayoutPanel() }
        .debugOpens("layout", $open)
    }
}

/// The layouts, the one in use checked; Customize opens Settings → Layout.
struct LayoutPanel: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav = PanelNav()

    var body: some View {
        let c = model.layout
        let presets = LayoutPreset.allCases
        let saved = SavedLayouts.sorted(model.savedLayouts)
        let actions: [() -> Void] = presets.map { p in { model.chooseLayout(p) } } + saved.map { e in { model.chooseSavedLayout(e.id) } }
            + [{ SettingsWindow.show(section: .layout) }]
        PanelCard(width: 300) {
            PanelSectionTitle("Layout")
            ForEach(Array(presets.enumerated()), id: \.element) { i, p in
                row(i, PanelRow(title: p.title, shortcut: "⌃⌘\(p.number)", checked: p == c.preset && c.userId == nil, highlighted: nav.index == i) {
                    Image(systemName: p.icon).font(T.icon(11)).foregroundStyle(T.text3)
                })
                .help(p.summary)
            }
            if !saved.isEmpty {
                PanelDivider()
                PanelSectionTitle("Your layouts")
                ForEach(Array(saved.enumerated()), id: \.element.id) { j, e in
                    let i = presets.count + j
                    row(i, PanelRow(title: e.file.name, shortcut: j < 2 ? "⌃⌘\(8 + j)" : nil, checked: c.userId == e.id, highlighted: nav.index == i) {
                        Image(systemName: e.file.base.icon).font(T.icon(11)).foregroundStyle(T.text3)
                    })
                    .help("Based on \(e.file.base.title)" + (e.file.author.isEmpty ? "" : ", by \(e.file.author)"))
                }
            }
            PanelDivider()
            let last = presets.count + saved.count
            row(last, PanelRow(title: "Customize Layout…", highlighted: nav.index == last) {
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

/// Drag the agent column's right edge: right makes it wider.
struct SideAgentResizeHandle: View {
    @EnvironmentObject var model: AppModel
    @State private var start: CGFloat?

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 6)
            .contentShape(Rectangle())
            .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = model.sideAgentWidth }
                    let r = AppModel.sideAgentWidths
                    model.sideAgentWidth = min(r.upperBound, max(r.lowerBound, (start ?? 420) + v.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: 3)
            .help("Drag to resize")
    }
}

// MARK: - Settings → Layout

struct LayoutSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var importer = LayoutImport.shared
    @ObservedObject private var previews = LayoutPreviewShot.shared
    @State private var message: String?

    var body: some View {
        let c = model.layout
        let customized = LayoutEdit.isCustomized(model.layoutStored)
        let saved = SavedLayouts.sorted(model.savedLayouts)
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Layout", desc: "One layout for the whole app. Each keeps its own changes below; switch with ⌃⌘1…\(LayoutPreset.allCases.count), the command palette, or the Layout button in the status bar.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(LayoutPreset.allCases) { p in card(p, on: p == c.preset && c.userId == nil) }
                }
                .padding(12)
            }
            SettingsGroup("Your layouts", desc: "Layouts you saved or imported. A layout is a small file (.\(LayoutFile.fileExtension)): it arranges Octomux's own parts and can't run anything.", trailing: {
                HStack(spacing: 8) {
                    Button("Import…", action: importFile)
                    Button("Save Current as New…", action: saveAsNew)
                }
                .controlSize(.small)
            }) {
                if let message {
                    Text(message).font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                        .padding(.horizontal, 14).padding(.top, 10)
                }
                if saved.isEmpty {
                    Text("None yet. Arrange a layout below, then Save Current as New; or import a file someone shared.")
                        .font(.system(size: T.k * 12)).foregroundStyle(T.text3).padding(14)
                }
                ForEach(saved, id: \.id) { e in savedRow(e.id, e.file, on: c.userId == e.id) }
            }
            SettingsGroup("\(c.title) layout", desc: customized ? "Changed from how it comes." : "As it comes.", trailing: {
                HStack(spacing: 8) {
                    Button("Export…") { export(nil) }
                    Button(c.userId == nil ? "Reset to \(c.preset.title)" : "Reset to the saved layout") { model.editLayout { LayoutEdit.reset(stored: $0) } }.disabled(!customized)
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
        .sheet(isPresented: Binding(get: { importer.pending != nil }, set: { if !$0 { importer.pending = nil } })) {
            if let p = importer.pending { LayoutImportSheet(candidate: p) { importer.pending = nil }.environmentObject(model) }
        }
        .onChange(of: importer.failed) { _, f in if let f { message = f; importer.failed = nil } }
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

    private func savedRow(_ id: String, _ f: LayoutFile, on: Bool) -> some View {
        let picture = SavedLayouts.preview(id).flatMap(NSImage.init(data:))
        return HStack(alignment: .top, spacing: 14) {
            LayoutThumbnail(tree: f.tree, base: f.base, picture: picture).frame(width: 150, height: 94)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(f.name).font(.system(size: T.k * 13, weight: .semibold))
                    if on { Text("In use").font(.system(size: T.k * 10, weight: .semibold)).foregroundStyle(T.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(T.accent.opacity(0.12))) }
                }
                Text(([f.author.isEmpty ? nil : "by \(f.author)", "based on \(f.base.title)", f.tree == nil ? "\(f.base.title)'s window" : nil]
                    .compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: T.k * 11)).foregroundStyle(T.text3)
                HStack(spacing: 6) {
                    Button(on ? "In Use" : "Use") { model.chooseSavedLayout(id) }.disabled(on)
                    Button("Export…") { export(id) }
                    Button("Duplicate") { model.duplicateSavedLayout(id) }
                    if on { Button("Use the Window as Picture") { LayoutPreviewShot.take(for: id) }.help("Its picture in this list and in the files you export") }
                    Button("Delete…") { delete(id, f) }
                }
                .controlSize(.small).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .id(id + "\(previews.revision)")
    }

    private func region(_ r: LayoutRegion, _ c: LayoutConfig) -> some View {
        let items = c.items(r)
        let saved = model.savedLayouts
        return SettingsGroup(r.title, desc: r.desc) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        arrow("chevron.up", enabled: i > 0) { model.editLayout { LayoutEdit.move(it.id, in: r, by: -1, stored: $0, saved: saved) } }
                        arrow("chevron.down", enabled: i < items.count - 1) { model.editLayout { LayoutEdit.move(it.id, in: r, by: 1, stored: $0, saved: saved) } }
                    }
                    Text(LayoutRegion.itemTitle(it.id, in: r)).font(.system(size: T.k * 13)).foregroundStyle(it.on ? T.text : T.text3)
                    Spacer()
                    SettingSwitch(isOn: Binding(get: { it.on }, set: { v in model.editLayout { LayoutEdit.toggle(it.id, in: r, on: v, stored: $0, saved: saved) } }))
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

    // MARK: Actions

    private func saveAsNew() {
        let a = NSAlert()
        a.messageText = "Save “\(model.layout.title)” as a new layout"
        a.informativeText = "It keeps this window and its parts as they are now; you can share it as a file."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 22))
        name.placeholderString = "Name"
        name.stringValue = model.layout.userId == nil ? "My \(model.layout.preset.title)" : model.layout.title
        let author = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        author.placeholderString = "Your name (optional; goes in the files you share)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        box.addSubview(name); box.addSubview(author)
        a.accessoryView = box
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { message = "A layout needs a name."; return }
        model.saveLayoutAsNew(name: n, author: author.stringValue.trimmingCharacters(in: .whitespaces))
        message = "Saved “\(n)”."
    }

    private func export(_ id: String?) {
        let a = NSAlert()
        a.messageText = "Export \(id.flatMap { model.savedLayouts[$0]?.name } ?? model.layout.title)"
        a.informativeText = "The file has the window and its parts. Add your theme and shortcuts if you want them to travel too; whoever imports it decides whether to use them."
        let theme = NSButton(checkboxWithTitle: "Include my theme", target: nil, action: nil)
        let keys = NSButton(checkboxWithTitle: "Include my shortcuts", target: nil, action: nil)
        theme.frame = NSRect(x: 0, y: 24, width: 260, height: 20); keys.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        box.addSubview(theme); box.addSubview(keys)
        a.accessoryView = box
        a.addButton(withTitle: "Export…"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let f = model.layoutFileForExport(id, includeTheme: theme.state == .on, includeKeys: keys.state == .on)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = f.fileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try f.data().write(to: url); message = "Exported." }
        catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LayoutImport.shared.open(url, model: model)
    }

    private func delete(_ id: String, _ f: LayoutFile) {
        let a = NSAlert()
        a.messageText = "Delete “\(f.name)”?"
        a.informativeText = model.layout.userId == id ? "It is in use: the window goes back to \(f.base.title)." : "Export it first if you want to keep a copy."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { model.deleteSavedLayout(id) }
    }
}

// MARK: - Import

/// A layout file on its way in: read, shown, and added only when you say so.
final class LayoutImport: ObservableObject {
    static let shared = LayoutImport()
    struct Candidate { var file: LayoutFile; var notes: [String] }
    @Published var pending: Candidate?
    @Published var failed: String?
    /// The last debug import's outcome.
    nonisolated(unsafe) static var last = ""

    static func read(_ url: URL, model: AppModel) -> Result<(file: LayoutFile, notes: [String]), LayoutFile.Problem> {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= LayoutFile.maxBytes else { return .failure(.tooBig) }
        guard let d = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return LayoutFile.read(d, themes: model.knownThemes, commands: model.knownCommands)
    }

    func open(_ url: URL, model: AppModel) {
        switch Self.read(url, model: model) {
        case .success(let r): pending = Candidate(file: r.file, notes: r.notes)
        case .failure(let p): failed = "Not imported: " + p.message
        }
    }
}

/// What a file brings, before it is added: its window, name, base, what this Mac can't use; its theme and
/// shortcuts only when you tick them.
struct LayoutImportSheet: View {
    @EnvironmentObject var model: AppModel
    let candidate: LayoutImport.Candidate
    let close: () -> Void
    @State private var theme = false
    @State private var keys = false

    var body: some View {
        let f = candidate.file
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LayoutThumbnail(tree: f.tree, base: f.base, picture: f.preview.flatMap(NSImage.init(data:))).frame(width: 220, height: 138)
                VStack(alignment: .leading, spacing: 5) {
                    Text(f.name).font(.system(size: T.k * 16, weight: .semibold))
                    Text(([f.author.isEmpty ? nil : "by \(f.author)", "based on \(f.base.title)"].compactMap { $0 }).joined(separator: " · "))
                        .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
                    Text(Self.blocks(f)).font(.system(size: T.k * 11)).foregroundStyle(T.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("A layout file is data: it arranges Octomux's own parts. Nothing in it runs.")
                .font(.system(size: T.k * 12)).foregroundStyle(T.text2)
            ForEach(candidate.notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.system(size: T.k * 11)).foregroundStyle(T.text3)
            }
            if let t = f.theme {
                Toggle("Also use its theme (\(Themes.all.first { $0.id == t.id }?.name ?? t.id)\(t.mode.map { ", " + $0 } ?? ""))", isOn: $theme)
            }
            if !f.keys.isEmpty {
                let k = LayoutFile.usableKeys(f.keys, current: model.currentShortcuts)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Also use its \(k.use.count == 1 ? "shortcut" : "\(k.use.count) shortcuts") (yours for the same commands are replaced)", isOn: $keys)
                        .disabled(k.use.isEmpty)
                    ForEach(f.keys.keys.sorted(), id: \.self) { id in
                        HStack(spacing: 8) {
                            Text(Self.command(id)).foregroundStyle(T.text2)
                            Spacer()
                            if let other = k.clash[id] { Text("taken by \(Self.command(other)); left out").foregroundStyle(T.text3) }
                            Text(Shortcut(string: f.keys[id] ?? "")?.display ?? "").monospaced()
                                .foregroundStyle(k.clash[id] == nil ? T.text : T.text3).strikethrough(k.clash[id] != nil)
                        }
                        .font(.system(size: T.k * 11)).padding(.leading, 20)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add") { model.addLayout(f, use: false, applyTheme: theme, applyKeys: keys); close() }
                Button("Add and Use") { model.addLayout(f, use: true, applyTheme: theme, applyKeys: keys); close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// A menu command's name ("New Terminal Tab"), else its id.
    static func command(_ id: String) -> String { KeyBindings.shared.commands.first { $0.id == id }?.title ?? id }

    /// "Agent rail, Breadcrumb, Home (workday), Work area, Status bar" — the window's blocks in words.
    static func blocks(_ f: LayoutFile) -> String {
        guard let t = f.tree else { return "The \(f.base.title) window." }
        return "Window: " + t.root.blocks.map { b in
            let n = ShellBlock.title(b)
            return t.variant(of: b).map { "\(n) (\($0))" } ?? n
        }.joined(separator: ", ") + "."
    }
}

extension ShellBlock {
    static func title(_ b: ShellBlock) -> String {
        switch b {
        case .agentRail: return "Agent rail"
        case .projectTree: return "Projects"
        case .tasksRail: return "Tasks rail"
        case .tabStrip: return "Tabs"
        case .breadcrumb: return "Breadcrumb"
        case .workArea: return "Work area"
        case .home: return "Home"
        case .sidePanel: return "Side panel"
        case .taskDetail: return "Task detail"
        case .sideAgent: return "Agent column"
        case .aquariumStrip: return "Aquarium"
        case .statusBar: return "Status bar"
        }
    }
}

// MARK: - Pictures of a layout

/// A layout's picture: the window as you saved it, else its blocks drawn from the tree.
struct LayoutThumbnail: View {
    let tree: ShellTree?
    let base: LayoutPreset
    var picture: NSImage? = nil

    var body: some View {
        Group {
            if let picture { Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill) }
            else { LayoutSchematic(tree: tree ?? ShellTree.builtIn(base.rawValue) ?? ShellTree.builtIn("terminal")) }
        }
        .clipShape(RoundedRectangle(cornerRadius: R.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: R.md, style: .continuous).stroke(T.border))
    }
}

/// The window's blocks as boxes, in proportion (a 1320-point window): rails and bars at their sizes, the rest shared.
struct LayoutSchematic: View {
    let tree: ShellTree?

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / 1320
            Group {
                if let t = tree { node(ShellChild(node: t.root), k: k) } else { Color.clear }
            }
            .padding(3)
        }
        .background(T.surface)
    }

    private func node(_ c: ShellChild, k: CGFloat) -> AnyView {
        switch c.node {
        case .block(let b): return AnyView(box(b, variant: c.variant))
        case .row(let kids):
            return AnyView(HStack(spacing: 2) { ForEach(kids, id: \.key) { ch in sized(node(ch, k: k), ch, k: k, horizontal: true) } })
        case .column(let kids):
            return AnyView(VStack(spacing: 2) { ForEach(kids, id: \.key) { ch in sized(node(ch, k: k), ch, k: k, horizontal: false) } })
        case .stack(let kids):
            guard let s = ShellNode.shown(kids, home: true) else { return AnyView(EmptyView()) }
            return node(s, k: k)
        }
    }

    @ViewBuilder private func sized(_ v: AnyView, _ c: ShellChild, k: CGFloat, horizontal: Bool) -> some View {
        let fixed: CGFloat? = {
            if case .fixed(let w)? = c.size { return w }
            if case .block(let b) = c.node {
                if horizontal, b.kind == .rail { return b.defaultWidth }
                if !horizontal, b.kind == .bar { return b == .aquariumStrip ? 210 : b == .statusBar ? 28 : 40 }
            }
            return nil
        }()
        if let f = fixed {
            if horizontal { v.frame(width: max(6, f * k)) } else { v.frame(height: max(4, f * k)) }
        } else {
            if horizontal { v.frame(maxWidth: .infinity) } else { v.frame(maxHeight: .infinity) }
        }
    }

    private func box(_ b: ShellBlock, variant: String?) -> some View {
        let tone: Color = {
            switch b {
            case .workArea: return T.text3.opacity(0.18)
            case .home: return T.accent.opacity(0.22)
            case .agentRail, .tasksRail, .projectTree: return T.text2.opacity(0.22)
            case .sidePanel, .taskDetail, .sideAgent: return T.blue.opacity(0.22)
            case .aquariumStrip: return T.blue.opacity(0.35)
            default: return T.text3.opacity(0.28)
            }
        }()
        return RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tone)
            .overlay {
                if b.kind != .bar || b == .aquariumStrip {
                    Text(variant.map { ShellBlock.title(b) + " · " + $0 } ?? ShellBlock.title(b))
                        .font(.system(size: 7, weight: .medium)).foregroundStyle(T.text2).lineLimit(1).minimumScaleFactor(0.6).padding(2)
                }
            }
    }
}

/// The window as a saved layout's picture (Use the Window as Picture): the main window, 640 points wide.
final class LayoutPreviewShot: ObservableObject {
    static let shared = LayoutPreviewShot()
    @Published var revision = 0

    static func take(for id: String) {
        guard let w = (NSApp.delegate as? AppDelegate)?.mainWindow,
              let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .nominalResolution])
        else { return }
        let width = 640.0, scale = width / Double(cg.width)
        let size = NSSize(width: width, height: Double(cg.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        SavedLayouts.setPreview(id, png)
        shared.revision += 1
    }
}
