import SwiftUI

/// Small colored glyph per file type (Explorer, Changes list, file tabs).
struct FileIcon: View {
    let name: String
    var size: CGFloat = 11

    var body: some View {
        let s = Self.style(for: name)
        Image(systemName: s.symbol)
            .font(.system(size: T.k * size, weight: .medium))
            .foregroundStyle(s.color)
            .frame(width: size + 4)
    }

    struct Style { let symbol: String; let color: Color }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func style(for name: String) -> Style {
        let n = name.lowercased()
        let ext = (n as NSString).pathExtension
        switch n {
        case "dockerfile", ".dockerignore", "docker-compose.yml", "compose.yaml", "compose.yml": return Style(symbol: "shippingbox.fill", color: hex(0x2496ED))
        case ".gitignore", ".gitattributes", ".gitmodules": return Style(symbol: "arrow.triangle.branch", color: hex(0xF05033))
        case "makefile", "justfile": return Style(symbol: "hammer.fill", color: hex(0x9A8F7A))
        case "license", "license.md", "license.txt": return Style(symbol: "checkmark.seal.fill", color: hex(0xD4A72C))
        case "readme.md", "readme": return Style(symbol: "info.circle.fill", color: hex(0x519ABA))
        case "package.json", "package-lock.json": return Style(symbol: "shippingbox", color: hex(0xCB3837))
        case "cargo.toml", "cargo.lock": return Style(symbol: "shippingbox", color: hex(0xDEA584))
        default: break
        }
        if n.hasPrefix(".env") { return Style(symbol: "key.fill", color: hex(0xE5B04A)) }
        switch ext {
        case "swift": return Style(symbol: "swift", color: hex(0xF05138))
        case "rs": return Style(symbol: "gearshape.fill", color: hex(0xDEA584))
        case "go": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0x00ADD8))
        case "py", "pyi": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0x4B8BBE))
        case "ts", "tsx", "mts", "cts": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0x3178C6))
        case "js", "jsx", "mjs", "cjs": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0xE8C547))
        case "java", "kt", "kts", "scala": return Style(symbol: "cup.and.saucer.fill", color: hex(0xE76F00))
        case "c", "h", "cc", "cpp", "hpp", "m", "mm": return Style(symbol: "c.square.fill", color: hex(0x659AD2))
        case "rb": return Style(symbol: "diamond.fill", color: hex(0xCC342D))
        case "php": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0x8892BF))
        case "html", "htm", "vue", "svelte": return Style(symbol: "globe", color: hex(0xE34C26))
        case "css", "scss", "less": return Style(symbol: "paintbrush.fill", color: hex(0x563D7C))
        case "md", "markdown", "mdx", "txt", "rst": return Style(symbol: "doc.text.fill", color: hex(0x519ABA))
        case "json", "jsonc", "json5": return Style(symbol: "curlybraces", color: hex(0xCBCB41))
        case "yml", "yaml", "toml", "ini", "conf", "cfg", "plist", "properties": return Style(symbol: "slider.horizontal.3", color: hex(0xA074C4))
        case "lock": return Style(symbol: "lock.fill", color: hex(0x8A8F98))
        case "sh", "bash", "zsh", "fish": return Style(symbol: "terminal.fill", color: hex(0x4EAA25))
        case "sql", "db", "sqlite": return Style(symbol: "cylinder.fill", color: hex(0xE38C00))
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "heic", "bmp": return Style(symbol: "photo.fill", color: hex(0xA074C4))
        case "svg": return Style(symbol: "scribble.variable", color: hex(0xFFB13B))
        case "pdf": return Style(symbol: "doc.richtext.fill", color: hex(0xE5252A))
        case "zip", "gz", "tar", "tgz", "xz", "7z": return Style(symbol: "archivebox.fill", color: hex(0x9A8F7A))
        case "xml", "xib", "storyboard": return Style(symbol: "chevron.left.slash.chevron.right", color: hex(0xE37933))
        case "lua": return Style(symbol: "moon.fill", color: hex(0x000080))
        case "dart": return Style(symbol: "chevron.left.forwardslash.chevron.right", color: hex(0x00B4AB))
        case "cs": return Style(symbol: "number.square.fill", color: hex(0x68217A))
        default: return Style(symbol: "doc", color: T.text3)
        }
    }
}

/// Folder glyph: tinted when the folder holds changed files.
struct FolderIcon: View {
    let open: Bool
    var tint: Color? = nil
    var body: some View {
        Image(systemName: open ? "folder.fill" : "folder.fill")
            .font(.system(size: T.k * 11)).foregroundStyle(tint ?? T.text3.opacity(0.9))
            .frame(width: 15)
    }
}
