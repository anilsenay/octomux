import SwiftUI

/// Settings → Terminal: controls for the common terminal.conf keys, the close confirmation, and the
/// config file itself. A control saves its key right away (terminals update live); the editor below
/// shows the same file and keeps its own unsaved edits.
struct TerminalSettings: View {
    @State private var disk = TerminalConfig.load()
    @State private var editor = TerminalConfig.load().text
    @State private var status = ""
    @State private var families: [String] = []
    @AppStorage(AppModel.confirmCloseKey) private var confirmClose = true

    var body: some View {
        SettingsGroup("Font", desc: "Terminals update as you change these.") {
            SettingBlock { TerminalTextPreview(config: disk) }
            SettingRow("Font", desc: disk.fontFamily == nil ? "\(TerminalConfig.builtInFont) ships with Octomux and is used when no font is set." : nil) {
                Menu {
                    Button("Default (\(TerminalConfig.builtInFont))") { set("font-family", nil) }
                    Divider()
                    ForEach(menuFamilies, id: \.self) { f in
                        Button { set("font-family", f) } label: {
                            if f == disk.fontFamily { Label(f, systemImage: "checkmark") } else { Text(f) }
                        }
                    }
                } label: {
                    Text(disk.fontFamily ?? "Default (\(TerminalConfig.builtInFont))").font(.system(size: 12.5))
                }
                .menuStyle(.button).fixedSize()
            }
            SettingRow("Size") {
                stepper(value: Self.trim(disk.fontSize) + " pt",
                        minus: disk.fontSize > 6, plus: disk.fontSize < 36,
                        step: { d in
                            let v = (disk.fontSize + Double(d)).rounded()
                            set("font-size", v == TerminalConfig.defaultFontSize ? nil : Self.trim(v))
                        })
            }
            SettingRow("Line height", desc: "Extra room between lines, on top of what the font asks for.") {
                let p = disk.lineHeightPercent
                stepper(value: p == 0 ? "Normal" : (p > 0 ? "+\(p)%" : "\(p)%"),
                        minus: p > -20, plus: p < 80,
                        step: { d in
                            let v = p + d * 5
                            set("adjust-cell-height", v == 0 ? nil : "\(v)%")
                        })
            }
        }
        .onAppear { if families.isEmpty { families = TerminalConfig.monospacedFamilies() } }

        SettingsGroup("Cursor") {
            VisualSettingRow("Cursor style", desc: "Programs can still set their own; many agents and editors do.") {
                HStack(spacing: 12) {
                    ForEach([("block", "Block"), ("bar", "Bar"), ("underline", "Underline"), ("block_hollow", "Hollow")], id: \.0) { id, name in
                        ChoiceTile(title: name, selected: disk.cursorStyle == id, width: 96, height: 58,
                                   action: { set("cursor-style", id == "block" ? nil : id) }) {
                            CursorPreview(style: id)
                        }
                    }
                }
            }
            SettingRow("Blink") {
                SettingSwitch(isOn: Binding(get: { disk.cursorBlink != false }, set: { set("cursor-style-blink", $0 ? nil : "false") }))
            }
        }

        SettingsGroup("Scrollback") {
            SettingRow("Lines to keep", desc: "History a terminal keeps while it is open (and at most 50 MB per terminal). When a terminal opens again, after Octomux restarts, the daemon brings back its last 3,000 lines.") {
                Picker("", selection: Binding(get: { disk.scrollbackLines ?? 0 }, set: { set("scrollback-limit-lines", $0 == 0 ? nil : String($0)) })) {
                    ForEach(Self.scrollbackChoices(current: disk.scrollbackLines), id: \.self) { n in
                        Text(n == 0 ? "Unlimited" : n.formatted()).tag(n)
                    }
                }
                .labelsHidden().fixedSize()
            }
        }

        SettingsGroup("Closing") {
            SettingRow("Ask before closing a running program", desc: "When you close a tab or pane where an agent is working or waiting for you, or where a program other than the shell runs (a dev server, vim, a build).") {
                SettingSwitch(isOn: $confirmClose)
            }
        }

        SettingsGroup("Config file", desc: "Everything else Ghostty's config syntax offers. The controls above edit these same lines. The theme's colors go on top unless “Use theme colors in the terminal” (Appearance) is off.") {
            SettingBlock {
                TextEditor(text: $editor).font(T.mono(12)).frame(height: 200)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border))
                HStack(spacing: 8) {
                    Button("Import from Ghostty") { importGhostty() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Text(editor != disk.text ? "Unsaved changes" : status).font(.caption).foregroundStyle(T.text2)
                    Button("Revert") { editor = disk.text; status = "" }.buttonStyle(SecondaryButtonStyle()).disabled(editor == disk.text)
                    Button("Apply") { apply() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("s")
                }
            }
            .settingAnchor("Config file")
        }
        SettingsFootnote("Saved to \(Paths.terminalConfig.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
    }

    /// The font menu: installed fixed-pitch families, plus the one the file names if it isn't among them.
    private var menuFamilies: [String] {
        guard let f = disk.fontFamily, !families.contains(f) else { return families }
        return [f] + families
    }

    static func scrollbackChoices(current: Int?) -> [Int] {
        var c = [1_000, 10_000, 100_000, 0]
        if let current, !c.contains(current) { c.insert(current, at: 0); c.sort { $0 == 0 ? false : $1 == 0 ? true : $0 < $1 } }
        return c
    }

    static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    private func stepper(value: String, minus: Bool, plus: Bool, step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }.disabled(!minus)
            Text(value).font(.system(size: 12.5).monospacedDigit()).frame(minWidth: 64)
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }.disabled(!plus)
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(T.border))
    }

    /// Saves one key to the file, and makes the same edit in the editor (its other unsaved edits stay).
    private func set(_ key: String, _ value: String?) {
        var d = TerminalConfig.load()
        d.set(key, value)
        do {
            try d.save()
            disk = d
            var e = TerminalConfig(text: editor)
            e.set(key, value)
            editor = e.text
            status = "Saved"
        } catch { status = "\(error.localizedDescription)" }
    }

    private func apply() {
        let c = TerminalConfig(text: editor)
        do { try c.save(); disk = c; status = "Applied" } catch { status = "\(error.localizedDescription)" }
    }

    private func importGhostty() {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.config/ghostty/config", "\(home)/.config/ghostty/config.ghostty",
                          "\(home)/Library/Application Support/com.mitchellh.ghostty/config"]
        for c in candidates {
            if let s = try? String(contentsOfFile: c, encoding: .utf8) {
                // Keybinds and window options belong to Ghostty.app, not to us.
                let kept = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !(t.hasPrefix("keybind") || t.hasPrefix("window-") && !t.hasPrefix("window-padding") || t.hasPrefix("quick-terminal") || t.hasPrefix("macos-"))
                }
                editor = "# Imported from \(c)\n" + kept.joined(separator: "\n")
                status = "Imported — press Apply"
                return
            }
        }
        status = "No Ghostty config found"
    }
}

/// A few terminal lines in the chosen font, size, line height and cursor.
struct TerminalTextPreview: View {
    let config: TerminalConfig

    var body: some View {
        let size = CGFloat(config.fontSize)
        let font = Self.nsFont(config.fontFamily, size: size)
        let lineH = (font.ascender - font.descender + font.leading) * (1 + CGFloat(config.lineHeightPercent) / 100)
        let extra = max(0, lineH - (font.ascender - font.descender + font.leading))
        VStack(alignment: .leading, spacing: extra) {
            line([("~/octomux", T.accent), (" ❯ ", T.text3), ("cargo test", T.text)])
            line([("test holder::resize_safety ... ", T.text2), ("ok", T.green)])
            line([("test result: ", T.text2), ("ok", T.green), (". 39 passed; 0 failed", T.text2)])
            HStack(spacing: 0) {
                line([("~/octomux", T.accent), (" ❯ ", T.text3)])
                CursorMark(style: config.cursorStyle, width: font.maximumAdvancement.width > 0 ? font.maximumAdvancement.width : size * 0.6, height: size * 1.2)
            }
        }
        .font(Font(font))
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border))
        .overlay(alignment: .topTrailing) {
            Text("\(config.fontFamily ?? TerminalConfig.builtInFont) · \(TerminalSettings.trim(config.fontSize)) pt")
                .font(.system(size: 10.5)).foregroundStyle(T.text3).padding(8)
        }
    }

    private func line(_ parts: [(String, Color)]) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor($1.1) }
    }

    static func nsFont(_ family: String?, size: CGFloat) -> NSFont {
        let fam = family ?? TerminalConfig.builtInFont
        if let f = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size) { return f }
        return NSFont(name: fam, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The cursor drawn in one of Ghostty's styles.
struct CursorMark: View {
    let style: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        switch style {
        case "bar": Rectangle().fill(T.text).frame(width: max(1.5, width * 0.14), height: height).frame(width: width, alignment: .leading)
        case "underline": Rectangle().fill(T.text).frame(width: width, height: max(1.5, height * 0.1)).frame(height: height, alignment: .bottom)
        case "block_hollow": Rectangle().stroke(T.text, lineWidth: 1).frame(width: width, height: height)
        default: Rectangle().fill(T.text.opacity(0.85)).frame(width: width, height: height)
        }
    }
}

struct CursorPreview: View {
    let style: String
    var body: some View {
        HStack(spacing: 1) {
            Text("ls").font(T.mono(13)).foregroundStyle(T.text2)
            CursorMark(style: style, width: 8, height: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.surface)
    }
}
