import SwiftUI

/// Octomux's octopus from the app icon, drawn pixel by pixel (no icon background), for empty states.
struct OctoMark: View {
    var size: CGFloat = 64
    private static let rows = [
        ".....aaaaaa.....",
        "...abbbaaaaaa...",
        "..abbbaaaaaaaa..",
        ".aabbaaaaaaaaac.",
        ".aaaaaaaaaaaaac.",
        ".aaadeaaaadeaac.",
        ".aaaeeaaaaeeaac.",
        ".aaaeeaaaaeeaac.",
        ".afaaaaaaaaaafc.",
        "..aaaaaaaaaaac..",
        ".aa.aa.aa.aa.aa.",
        "aa..a..aa..a..aa",
        "a...a..aa..a...a"
    ]
    private static let colors: [Character: Color] = [
        "a": Color(hex: "#8B5CF6"),
        "b": Color(hex: "#C4B5FD"),
        "c": Color(hex: "#6D28D9"),
        "d": Color(hex: "#FFFFFF"),
        "e": Color(hex: "#1E1B4B"),
        "f": Color(hex: "#F9A8D4")
    ]
    var body: some View {
        let cols = CGFloat(Self.rows[0].count), lines = CGFloat(Self.rows.count)
        Canvas { ctx, sz in
            let px = min(sz.width / cols, sz.height / lines)
            for (y, row) in Self.rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    guard let c = Self.colors[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)), with: .color(c))
                }
            }
        }
        .frame(width: size, height: size * lines / cols)
        .accessibilityLabel("Octomux")
    }
}
