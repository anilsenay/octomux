import Foundation

/// A short view of a page snapshot: its landmarks (banner, main, forms, dialogs…) and what an agent reads or acts on
/// (headings, links, buttons, fields), each with its ref; text, images and layout boxes left out. What a newly opened
/// page returns, so opening a page costs a fraction of the whole snapshot (browser_snapshot gives that).
enum SnapshotOutline {
    /// Kept, with their kept children under them.
    static let containers: Set<String> = ["banner", "navigation", "main", "contentinfo", "complementary", "search", "form",
                                          "dialog", "alertdialog", "region", "tablist", "menu", "menubar", "listbox",
                                          "radiogroup", "tabpanel", "table", "toolbar"]
    /// Kept as one line: their name already says what is inside.
    static let leaves: Set<String> = ["heading", "link", "button", "textbox", "searchbox", "combobox", "checkbox", "radio",
                                      "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "slider",
                                      "spinbutton", "alert"]
    static let maxName = 60
    static let maxLength = 8_000

    static func outline(_ yaml: String) -> String {
        var out: [String] = []
        var stack: [Int] = []      // indents of the kept containers above this line
        var skipBelow: Int?        // inside a kept leaf: its children are left out
        var lastLeaf: Int?         // out index of the last kept leaf (an unnamed link takes its /url)
        var leafIndent = 0
        var length = 0
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if let s = skipBelow {
                if indent > s {
                    // An unnamed link: its address says where it goes.
                    if indent == leafIndent + 2, body.hasPrefix("- /url: "), let i = lastLeaf, out[i].contains("- link [") {
                        out[i] += " → " + body.dropFirst(8)
                    }
                    continue
                }
                skipBelow = nil
            }
            guard body.hasPrefix("- ") else { continue }
            let rest = body.dropFirst(2)
            let role = String(rest.prefix { $0.isLetter })
            while let last = stack.last, last >= indent { stack.removeLast() }
            let isLeaf = leaves.contains(role)
            guard isLeaf || containers.contains(role) else { continue }
            var text = String(rest).replacingOccurrences(of: " [cursor=pointer]", with: "")
            text = shortened(text)
            if isLeaf, text.hasSuffix(":") { text.removeLast() }
            let l = String(repeating: "  ", count: stack.count) + "- " + text
            length += l.count + 1
            if length > maxLength {
                out.append("# … more below: browser_snapshot reads the whole page.")
                break
            }
            out.append(l)
            if isLeaf { skipBelow = indent; leafIndent = indent; lastLeaf = out.count - 1 } else { stack.append(indent) }
        }
        return out.joined(separator: "\n")
    }

    /// A long quoted name cut to `maxName` characters.
    private static func shortened(_ text: String) -> String {
        guard let open = text.firstIndex(of: "\""),
              let close = text[text.index(after: open)...].firstIndex(of: "\"") else { return text }
        let name = text[text.index(after: open)..<close]
        guard name.count > maxName else { return text }
        return String(text[...open]) + name.prefix(maxName - 1) + "…" + String(text[close...])
    }
}
