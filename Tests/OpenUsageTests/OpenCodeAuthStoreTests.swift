import XCTest
@testable import OpenUsage

/// Go-key detection from `auth.json`, including tolerance of unrelated sibling entries (regression for the
/// atomic-decode gap that let one odd top-level value hide a valid `opencode-go` key).
final class OpenCodeAuthStoreTests: XCTestCase {
    private func store(_ json: String) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: FakeFiles(["/oc/auth.json": json]),
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    func testReadsGoKey() {
        XCTAssertEqual(store(#"{"opencode-go":{"type":"api","key":"sk-abc"}}"#).goAPIKey(), "sk-abc")
    }

    func testToleratesNonObjectSiblingEntries() {
        // A future schema marker (string) and an array entry beside opencode-go must not hide the key.
        let json = #"{"$schema":"https://opencode.ai/auth.json","opencode-go":{"type":"api","key":"sk-xyz"},"weird":["a","b"]}"#
        XCTAssertEqual(store(json).goAPIKey(), "sk-xyz")
    }

    func testCoexistsWithOtherProviderEntries() {
        let json = #"{"openai":{"type":"oauth","access":"x","refresh":"y"},"opencode-go":{"type":"api","key":"sk-1"}}"#
        XCTAssertEqual(store(json).goAPIKey(), "sk-1")
    }

    func testMissingEmptyOrAbsentKeyIsNil() {
        XCTAssertNil(store(#"{"opencode-go":{"type":"api"}}"#).goAPIKey())
        XCTAssertNil(store(#"{"opencode-go":{"type":"api","key":"   "}}"#).goAPIKey())
        XCTAssertNil(store(#"{"openai":{"type":"oauth"}}"#).goAPIKey())
        XCTAssertNil(store("not json").goAPIKey())
    }
}
