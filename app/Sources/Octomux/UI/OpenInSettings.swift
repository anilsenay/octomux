import SwiftUI
import UniformTypeIdentifiers

/// Settings → General → Open in: which apps the Open in menus list, in what order, and the default (⌘O).
struct OpenInSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Read through the model so the page redraws when the settings change.
        let _ = model.state.settings.count
        let apps = OpenIn.installed
        let hidden = Set(strings("open_in.hidden"))
        SettingsGroup("Open in", desc: "The apps in every Open in menu (sidebar, file previews, the top bar's button). Apps that aren't on this Mac are left out.", trailing: {
            Button { addApp() } label: { Label("Add App…", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
        }) {
            SettingRow("Default app", desc: "The top bar's button and ⌘O open the project here.") {
                Picker("", selection: Binding(get: { OpenIn.defaultAppId }, set: { model.setSetting("open_in.default", $0) })) {
                    ForEach(apps.filter { !hidden.contains($0.id) }) { a in Text(a.name).tag(a.id) }
                }
                .labelsHidden().fixedSize()
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 10) {
                    if let u = a.url ?? (a.id == "com.apple.finder" ? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") : nil) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 20, height: 20)
                    }
                    Text(a.name).font(.system(size: 13)).foregroundStyle(hidden.contains(a.id) ? T.text3 : T.text)
                    if a.id == OpenIn.defaultAppId {
                        Text("Default").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(T.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(T.accent.opacity(0.14)))
                    }
                    Spacer()
                    Button { move(a.id, by: -1, in: apps) } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(ChromeButtonStyle()).disabled(i == 0).help("Move up")
                    Button { move(a.id, by: 1, in: apps) } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(ChromeButtonStyle()).disabled(i == apps.count - 1).help("Move down")
                    if OpenIn.customIds.contains(a.id) {
                        Button { remove(a.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                            .buttonStyle(ChromeButtonStyle()).help("Remove from the list")
                    }
                    SettingSwitch(isOn: Binding(get: { !hidden.contains(a.id) }, set: { setHidden(a.id, !$0) }))
                        .disabled(a.id == OpenIn.defaultAppId && !hidden.contains(a.id))
                        .help(a.id == OpenIn.defaultAppId ? "The default app is always listed" : "Show in Open in menus")
                }
                .padding(.horizontal, 14).frame(height: 40)
            }
        }
    }

    private func strings(_ key: String) -> [String] {
        guard case .array(let a)? = model.settingValue(key, scope: "global") else { return [] }
        return a.compactMap(\.string)
    }

    private func move(_ id: String, by d: Int, in apps: [ExternalApp]) {
        var ids = apps.map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + d) else { return }
        ids.swapAt(i, i + d)
        model.setSetting("open_in.order", ids)
    }

    private func setHidden(_ id: String, _ hide: Bool) {
        var h = strings("open_in.hidden").filter { $0 != id }
        if hide { h.append(id) }
        model.setSetting("open_in.hidden", h.isEmpty ? nil : h)
    }

    private func remove(_ id: String) {
        let c = strings("open_in.custom").filter { $0 != id }
        model.setSetting("open_in.custom", c.isEmpty ? nil : c)
        setHidden(id, false)
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Add"
        guard p.runModal() == .OK, let url = p.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !OpenIn.installed.contains(where: { $0.id == id }) {
            model.setSetting("open_in.custom", strings("open_in.custom") + [id])
        }
        setHidden(id, false)
    }
}
