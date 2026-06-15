import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testGrokResolvesToVectorMarkNotBoltFallback() {
        let mark = ProviderMarks.mark(for: "grok")
        XCTAssertNotNil(mark, "Grok must load a real vector mark instead of the bolt.fill fallback")
        XCTAssertEqual(mark?.viewBox.width ?? 0, 527.27, accuracy: 0.01)
        XCTAssertEqual(mark?.viewBox.height ?? 0, 578.68, accuracy: 0.01)
    }

    func testDevinUsesItsOwnViewBoxSoItFillsTheFrame() {
        let mark = ProviderMarks.mark(for: "devin")
        XCTAssertNotNil(mark)
        // Devin's source art is authored in a 44x50 box; honoring it is what makes the icon fill.
        XCTAssertEqual(mark?.viewBox.width ?? 0, 44, accuracy: 0.01)
        XCTAssertEqual(mark?.viewBox.height ?? 0, 50, accuracy: 0.01)
    }

    func testHundredUnitMarksAreUnchanged() {
        for id in ["claude", "codex", "cursor"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertEqual(mark?.viewBox.width ?? 0, 100, accuracy: 0.01)
            XCTAssertEqual(mark?.viewBox.height ?? 0, 100, accuracy: 0.01)
        }
    }
}
