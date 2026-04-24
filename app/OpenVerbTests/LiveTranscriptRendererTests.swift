import XCTest
@testable import OpenVerb

final class LiveTranscriptRendererTests: XCTestCase {

    func testDraftTokensPreserveWordsAndStatus() {
        let tokens = LiveTranscriptRenderer.tokens(
            from: "Today we launch",
            status: .confirmed
        )

        XCTAssertEqual(tokens.map(\.display), ["Today", "we", "launch"])
        XCTAssertEqual(tokens.map(\.status), [.confirmed, .confirmed, .confirmed])
        XCTAssertEqual(tokens.map(\.id), [0, 1, 2])
    }

    func testRevisionMarksWrongAndCorrectionTokens() {
        let tokens = LiveTranscriptRenderer.revisionTokens(
            raw: "we launch on timming",
            polished: "we launch on timing"
        )

        XCTAssertEqual(tokens.map(\.display), ["we", "launch", "on", "timming", "timing"])
        XCTAssertEqual(tokens.map(\.status), [.confirmed, .confirmed, .confirmed, .wrong, .correction])
    }

    func testRevisionMatchesWordsIgnoringPunctuationAndCase() {
        let tokens = LiveTranscriptRenderer.revisionTokens(
            raw: "Today, WE launch",
            polished: "today we launch."
        )

        XCTAssertEqual(tokens.map(\.display), ["today", "we", "launch."])
        XCTAssertEqual(tokens.map(\.status), [.confirmed, .confirmed, .confirmed])
    }

    func testPolishedOnlyTextBecomesCorrectionWhenRawIsEmpty() {
        let tokens = LiveTranscriptRenderer.revisionTokens(
            raw: "",
            polished: "Clean final text"
        )

        XCTAssertEqual(tokens.map(\.display), ["Clean", "final", "text"])
        XCTAssertEqual(tokens.map(\.status), [.correction, .correction, .correction])
    }
}
