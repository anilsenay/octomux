import XCTest
@testable import Octomux

/// The type scale and radius scale stay closed: no half-point font sizes and no off-scale corner radii in UI code.
final class DesignTokenTests: XCTestCase {
    private var uiSources: [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Octomux/UI")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }.compactMap { u in (try? String(contentsOf: u, encoding: .utf8)).map { (u.lastPathComponent, $0) } }
    }

    func testNoHalfPointFontSizes() throws {
        let re = try NSRegularExpression(pattern: #"T\.k \* \d+\.5\b|T\.mono\(\d+\.5"#)
        var hits: [String] = []
        for (name, text) in uiSources {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                hits.append("\(name): \((text as NSString).substring(with: m.range))")
            }
        }
        XCTAssertFalse(uiSources.isEmpty)
        XCTAssertEqual(hits, [], "use the type scale (10 · 11 · 12 · 13 · 15 · 20 · 22)")
    }

    func testCornerRadiiOnScale() throws {
        let re = try NSRegularExpression(pattern: #"cornerRadius: (\d+(?:\.\d+)?)[,)]"#)
        let allowed: Set<Double> = [1, 1.5, 2, 2.5, 3, 4, 6, 8, 10, 12, 14]
        var hits: [String] = []
        for (name, text) in uiSources {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let v = Double((text as NSString).substring(with: m.range(at: 1))) ?? 0
                if !allowed.contains(v) { hits.append("\(name): \(v)") }
            }
        }
        XCTAssertEqual(hits, [], "radii: 4 · 6 · 8 · 10 · 12 · 14 (R.*)")
    }

    func testIconButtonSizesSnapToThree() {
        XCTAssertEqual([14, 16, 18, 20, 22, 24, 26, 28].map { IconButtonStyle.snap($0) }, [18, 18, 18, 22, 22, 26, 26, 26])
    }
}
