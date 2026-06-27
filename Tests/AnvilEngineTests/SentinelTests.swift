import XCTest
@testable import AnvilEngine

final class SentinelTests: XCTestCase {

    func testParsesCleanNeedsInput() {
        let text = """
        <<<ANVIL:NEEDS_INPUT>>>
        {"question": "Pick one", "options": ["a", "b"]}
        <<<ANVIL:END>>>
        """
        XCTAssertEqual(Sentinel.parse(text), .value(.needsInput(question: "Pick one", options: ["a", "b"])))
    }

    func testParsesNeedsInputAfterProsePreamble() {
        let text = """
        Here is my reasoning about the situation, which spans a paragraph.
        I cannot proceed without a decision.
        <<<ANVIL:NEEDS_INPUT>>>
        {"question": "Pick one", "options": ["a", "b"]}
        <<<ANVIL:END>>>
        """
        XCTAssertEqual(Sentinel.parse(text), .value(.needsInput(question: "Pick one", options: ["a", "b"])))
    }

    func testParsesDone() {
        let text = """
        <<<ANVIL:DONE>>>
        {"summary": "all good"}
        <<<ANVIL:END>>>
        """
        XCTAssertEqual(Sentinel.parse(text), .value(.done(summary: "all good")))
    }

    func testNoSentinelReturnsNone() {
        XCTAssertEqual(Sentinel.parse("Just some prose with no markers."), .none)
    }

    func testMarkerWithMalformedJSONReturnsMalformed() {
        let text = """
        <<<ANVIL:NEEDS_INPUT>>>
        {"question": "broken" "options": [oops]}
        <<<ANVIL:END>>>
        """
        XCTAssertEqual(Sentinel.parse(text), .malformed)
    }

    func testLastMarkerWins() {
        // A DONE mentioned in prose must not beat a trailing NEEDS_INPUT block.
        let text = """
        Earlier I thought I was <<<ANVIL:DONE>>> but actually not.
        <<<ANVIL:NEEDS_INPUT>>>
        {"question": "Still need this", "options": ["x"]}
        <<<ANVIL:END>>>
        """
        XCTAssertEqual(Sentinel.parse(text), .value(.needsInput(question: "Still need this", options: ["x"])))
    }

    func testNeedsInputWithoutEndDelimiter() {
        // The closing delimiter is optional; the trailing JSON should still parse.
        let text = """
        <<<ANVIL:NEEDS_INPUT>>>
        {"question": "no end marker", "options": []}
        """
        XCTAssertEqual(Sentinel.parse(text), .value(.needsInput(question: "no end marker", options: [])))
    }
}
