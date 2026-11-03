import AppKit
import WebKit

/// Keeps one web-backed view per doc tab, so switching tabs keeps scroll and expand state.
final class DocHost {
    static let shared = DocHost()
    private var controllers: [String: DocController] = [:]

    func controller(for doc: DocTab) -> DocController {
        if let c = controllers[doc.id] { return c }
        let c = DocController(doc: doc)
        controllers[doc.id] = c
        return c
    }

    func isDirty(_ id: String) -> Bool { controllers[id]?.dirty ?? false }

    func drop(_ id: String) {
        controllers[id]?.close()
        controllers.removeValue(forKey: id)
    }

    /// Theme or workspace tint changed.
    func refreshTheme() { controllers.values.forEach { $0.applyTheme() } }

    /// Only the visible doc polls git / the file system.
    func activeChanged(_ id: String?) { controllers.values.forEach { $0.setActive($0.doc.id == id) } }
}

/// Where index.html + editor.js live: inside the .app, else the source tree (swift run / debug builds).
enum EditorAssets {
    static let dir: URL = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("editor"), FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // UI
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // app
            .appendingPathComponent("Resources/editor")
    }()
}

final class CodeWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class DocController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let doc: DocTab
    let web: CodeWebView
    private(set) var dirty = false
    private var ready = false
    private var queue: [String] = []
    private var timer: Timer?
    private var lastSig: String?
    private var fileMtime: Date?
    private var pendingScroll: String?
    private var mdMode: String?

    init(doc: DocTab) {
        self.doc = doc
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = CodeWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "octomux")
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.allowsMagnification = false
        web.loadFileURL(EditorAssets.dir.appendingPathComponent("index.html"), allowingReadAccessTo: EditorAssets.dir)
        applyTheme()
        load()
        NotificationCenter.default.addObserver(forName: .adeCompareBaseChanged, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? String) == self.doc.workPath, case .changes = self.doc.kind else { return }
            self.lastSig = nil
            self.load()
        }
    }

    func close() {
        timer?.invalidate()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "octomux")
        web.removeFromSuperview()
    }

    // MARK: JS bridge

    private func call(_ fn: String, _ arg: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]), let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.octomux && window.octomux.\(fn)(\(json))"
        if ready { web.evaluateJavaScript(js) } else { queue.append(js) }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            queue.forEach { web.evaluateJavaScript($0) }
            queue.removeAll()
        case "dirty":
            dirty = m["dirty"] as? Bool ?? false
        case "save":
            if let text = m["text"] as? String { save(text) }
        case "open":
            if let p = m["path"] as? String { AppModel.shared.openDoc(.file(p), workPath: doc.workPath) }
        case "mdMode":
            mdMode = m["mode"] as? String
        case "link":
            if let href = m["href"] as? String { openLink(href) }
        default: break
        }
    }

    // External links open in the browser; relative ones open as file tabs.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated {
            if let u = action.request.url, u.scheme != "file" { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func openLink(_ href: String) {
        if let u = URL(string: href), let s = u.scheme, s == "http" || s == "https" || s == "mailto" { NSWorkspace.shared.open(u); return }
        guard case .file(let rel) = doc.kind else { return }
        let clean = href.split(separator: "#").first.map(String.init) ?? href
        guard !clean.isEmpty else { return }
        let base = (rel as NSString).deletingLastPathComponent
        let target = ((base as NSString).appendingPathComponent(clean) as NSString).standardizingPath
        AppModel.shared.openDoc(.file(target.hasPrefix("/") ? String(target.dropFirst()) : target), workPath: doc.workPath)
    }

    // MARK: Theme

    func applyTheme() {
        let dark = ThemeStore.shared.isDark
        let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var vars: [String: String] = [:]
        ap.performAsCurrentDrawingAppearance {
            func css(_ c: NSColor, _ alpha: CGFloat? = nil) -> String {
                let x = c.usingColorSpace(.sRGB) ?? c
                return String(format: "rgba(%d,%d,%d,%.3f)", Int(round(x.redComponent * 255)), Int(round(x.greenComponent * 255)),
                              Int(round(x.blueComponent * 255)), alpha ?? x.alphaComponent)
            }
            let green = T.ns(\.green), red = T.ns(\.red), blue = T.ns(\.blue)
            vars = [
                "bg": css(WorkspaceTint.canvas(dark: dark)),
                "raised": css(T.ns(\.raised)),
                "text": css(T.ns(\.text)), "text2": css(T.ns(\.text2)), "text3": css(T.ns(\.text3)),
                "border": css(T.ns(\.border)), "hover": css(T.ns(\.hover)),
                "hover2": dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.07)",
                "selection": css(T.ns(\.accent), 0.28),
                "accent": css(T.ns(\.accent)), "green": css(green), "red": css(red), "blue": css(blue), "amber": css(T.ns(\.amber)),
                "add-bg": css(green, dark ? 0.12 : 0.13), "add-word": css(green, dark ? 0.22 : 0.20),
                "del-bg": css(red, dark ? 0.12 : 0.11), "del-word": css(red, dark ? 0.24 : 0.20),
                "hunk-bg": css(blue, dark ? 0.08 : 0.07),
                "mono": "\"\(T.monoName ?? "SF Mono")\", \"SF Mono\", ui-monospace, Menlo, monospace",
            ]
        }
        call("setTheme", ["dark": dark, "vars": vars])
    }

    // MARK: Content

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        if case .commit = doc.kind { return }
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.load() }
    }

    func scroll(to key: String) {
        pendingScroll = key
        if lastSig != nil { call("scrollToFile", key); pendingScroll = nil }
    }

    func goto(line: Int) {
        if case .file(let rel) = doc.kind { loadFile(rel, force: true, line: line) }
    }

    private var isRemote: Bool { AppModel.shared.host(forPath: doc.workPath).0.isRemote }

    func load() {
        switch doc.kind {
        case .file(let rel): loadFile(rel, force: false, line: nil)
        case .changes: loadChanges()
        case .commit(let h, let subject): loadCommit(h, subject)
        case .newChat: break
        }
    }

    private func loadFile(_ rel: String, force: Bool, line: Int?) {
        let full = (doc.workPath as NSString).appendingPathComponent(rel)
        let remote = isRemote
        DispatchQueue.global(qos: .userInitiated).async {
            var mtime: Date?
            if !remote { mtime = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date }
            DispatchQueue.main.async {
                let first = self.lastSig == nil
                if !force && !first {
                    // Polling: reload only when the file changed on disk (local) — remote files load once.
                    if remote || mtime == self.fileMtime { return }
                }
                self.fileMtime = mtime
                DispatchQueue.global(qos: .userInitiated).async {
                    let (text, binary, big) = GitDiffData.worktreeFile(self.doc.workPath, rel)
                    let exists = remote || FileManager.default.fileExists(atPath: full)
                    DispatchQueue.main.async {
                        if first || force {
                            var payload: [String: Any] = ["path": rel, "text": text, "binary": binary, "editable": !remote && !binary && !big]
                            if !exists { payload["error"] = "File not found" } else if big { payload["error"] = "File too large to open here" }
                            if let line { payload["line"] = line }
                            if let m = self.mdMode { payload["mode"] = m }
                            self.call("showFile", payload)
                        } else {
                            self.call("reload", text)
                        }
                        self.lastSig = "file"
                    }
                }
            }
        }
    }

    private func save(_ text: String) {
        guard case .file(let rel) = doc.kind, !isRemote else { return }
        let full = (doc.workPath as NSString).appendingPathComponent(rel)
        do {
            try text.write(toFile: full, atomically: true, encoding: .utf8)
            fileMtime = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            dirty = false
            call("saved", text)
        } catch {
            AppModel.shared.lastError = "Could not save \(rel): \(error.localizedDescription)"
        }
    }

    private var loading = false

    private func loadChanges() {
        guard !loading else { return }
        loading = true
        let dir = doc.workPath
        let prev = lastSig
        DispatchQueue.global(qos: .userInitiated).async {
            let baseName = GitInfo.compareBase(for: dir)
            let base = GitInfo.diffBase(for: dir)
            // Cheap signature first; the per-file blobs are read only when something changed.
            let sig = [GitInfo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: dir) ?? "-",
                       GitInfo.git(["diff", "--numstat"], in: dir) ?? "", GitInfo.git(["diff", "--cached", "--numstat"], in: dir) ?? "",
                       base ?? "", GitInfo.git(["rev-parse", "HEAD"], in: dir) ?? ""].joined(separator: "\u{1}")
            if sig == prev { DispatchQueue.main.async { self.loading = false }; return }
            if let base, let baseName {
                let files = GitDiffData.againstBase(dir, base)
                DispatchQueue.main.async {
                    self.loading = false
                    self.lastSig = sig
                    var payload: [String: Any] = ["title": "Changes against \(baseName)", "sections": [["title": "", "files": files.map(\.json)]],
                                                  "empty": "No changes against \(baseName)"]
                    if let s = self.pendingScroll { payload["scrollTo"] = s; self.pendingScroll = nil }
                    self.call("showDiff", payload)
                }
                return
            }
            let data = GitDiffData.workingTree(dir)
            DispatchQueue.main.async {
                self.loading = false
                self.lastSig = sig
                guard let data else {
                    self.call("showDiff", ["title": "", "sections": [], "empty": "Not a git repository"])
                    return
                }
                var sections: [[String: Any]] = []
                if !data.staged.isEmpty { sections.append(["title": "Staged", "files": data.staged.map(\.json)]) }
                sections.append(["title": data.staged.isEmpty ? "" : "Uncommitted", "files": data.unstaged.map(\.json)])
                var payload: [String: Any] = ["title": "Uncommitted changes", "sections": sections, "empty": "Working tree clean"]
                if let s = self.pendingScroll { payload["scrollTo"] = s; self.pendingScroll = nil }
                self.call("showDiff", payload)
            }
        }
    }

    private func loadCommit(_ hash: String, _ subject: String) {
        guard lastSig == nil else { return }
        lastSig = "commit"
        let dir = doc.workPath
        DispatchQueue.global(qos: .userInitiated).async {
            let files = GitDiffData.commit(hash, in: dir)
            let meta = GitInfo.git(["show", "-s", "--format=%h · %an · %ar", hash], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self.call("showDiff", ["title": "\(subject)  —  \(meta)", "sections": [["title": "", "files": files.map(\.json)]], "empty": "No file changes"])
            }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(uc, didReceive: m) }
}
