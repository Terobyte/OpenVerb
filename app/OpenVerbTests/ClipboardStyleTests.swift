import XCTest
@testable import OpenVerb

final class ClipboardStyleTests: XCTestCase {

    // MARK: describe() output format

    func testDescribeContainsAllSixFields() {
        let result = ClipboardStyle.describe("hello world")
        let fields = result.split(separator: ";")
        XCTAssertEqual(fields.count, 6)
        XCTAssertTrue(result.contains("len:"))
        XCTAssertTrue(result.contains("coding:"))
        XCTAssertTrue(result.contains("markdown:"))
        XCTAssertTrue(result.contains("url:"))
        XCTAssertTrue(result.contains("formality:"))
        XCTAssertTrue(result.contains("case:"))
    }

    func testDescribeReportsCorrectByteLength() {
        let result = ClipboardStyle.describe("hello")
        XCTAssertTrue(result.hasPrefix("len:5;"), "expected len:5 but got \(result)")
    }

    func testDescribeTruncatesAtByteLimit() {
        let bigText = String(repeating: "a", count: 20_000)
        let result = ClipboardStyle.describe(bigText)
        let lenField = result.split(separator: ";").first!
        let len = Int(lenField.dropFirst("len:".count))!
        XCTAssertLessThanOrEqual(len, ClipboardStyle.byteLimit)
    }

    func testByteLimitIsCorrect() {
        XCTAssertEqual(ClipboardStyle.byteLimit, 10_240)
    }

    // MARK: code detection

    func testDetectCodeTripleBacktick() {
        let result = ClipboardStyle.describe("```swift\nlet x = 1\n```")
        XCTAssertTrue(result.contains("coding:true"))
    }

    func testDetectCodeTripleTilde() {
        let result = ClipboardStyle.describe("~~~\nsome code\n~~~")
        XCTAssertTrue(result.contains("coding:true"))
    }

    func testNoCodeInPlainText() {
        let result = ClipboardStyle.describe("just some ordinary text here")
        XCTAssertTrue(result.contains("coding:false"))
    }

    // MARK: markdown detection

    func testMarkdownHeaderHash() {
        let result = ClipboardStyle.describe("# Title\nsome body text")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownBulletDash() {
        let result = ClipboardStyle.describe("- item one\n- item two")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownBulletAsterisk() {
        let result = ClipboardStyle.describe("* item one")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownBlockquote() {
        let result = ClipboardStyle.describe("> quoted text here")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownOrderedList() {
        let result = ClipboardStyle.describe("1. first item\n2. second item")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownHorizontalRule() {
        let result = ClipboardStyle.describe("---")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownBold() {
        let result = ClipboardStyle.describe("this is **bold** text")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownLink() {
        let result = ClipboardStyle.describe("[click here](https://example.com)")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testMarkdownInlineCode() {
        let result = ClipboardStyle.describe("use `let` to declare a constant")
        XCTAssertTrue(result.contains("markdown:true"))
    }

    func testPlainTextNotMarkdown() {
        let result = ClipboardStyle.describe("just a sentence with no markdown whatsoever")
        XCTAssertTrue(result.contains("markdown:false"))
    }

    // MARK: URL detection

    func testURLHttps() {
        let result = ClipboardStyle.describe("visit https://example.com today")
        XCTAssertTrue(result.contains("url:true"))
    }

    func testURLWww() {
        let result = ClipboardStyle.describe("check out www.example.com for details")
        XCTAssertTrue(result.contains("url:true"))
    }

    func testNoURL() {
        let result = ClipboardStyle.describe("no links here at all, none whatsoever")
        XCTAssertTrue(result.contains("url:false"))
    }

    // MARK: formality detection

    func testFormalityNeutral() {
        let result = ClipboardStyle.describe("The quarterly report has been submitted for review.")
        XCTAssertTrue(result.contains("formality:neutral"))
    }

    func testFormalityCasualMarkerLol() {
        let result = ClipboardStyle.describe("lol that was so funny yesterday")
        XCTAssertTrue(result.contains("formality:casual"))
    }

    func testFormalityCasualMarkerGonna() {
        let result = ClipboardStyle.describe("I'm gonna finish this tomorrow")
        XCTAssertTrue(result.contains("formality:casual"))
    }

    func testFormalityCasualMarkerBtw() {
        let result = ClipboardStyle.describe("btw did you see the game last night")
        XCTAssertTrue(result.contains("formality:casual"))
    }

    func testFormalityCasualMultipleExclamations() {
        let result = ClipboardStyle.describe("This is absolutely amazing!!!")
        XCTAssertTrue(result.contains("formality:casual"))
    }

    func testFormalityNoFalsePositiveAlcohol() {
        // "lol" must not match inside "alcohol" — Bug 126 fix: word-boundary regex
        let result = ClipboardStyle.describe("The alcohol content is 12 percent by volume.")
        XCTAssertTrue(result.contains("formality:neutral"),
                      "alcohol should not trigger lol word-boundary match, got: \(result)")
    }

    func testFormalityCasualHighUppercaseRatio() {
        // >60% uppercase letters should trigger casual
        let result = ClipboardStyle.describe("THIS IS COMPLETELY SHOUTED TEXT")
        XCTAssertTrue(result.contains("formality:casual"))
    }

    // MARK: case detection

    func testCaseAllUppercase() {
        let result = ClipboardStyle.describe("HELLO WORLD")
        XCTAssertTrue(result.contains("case:upper"), "got: \(result)")
    }

    func testCaseAllLowercase() {
        let result = ClipboardStyle.describe("hello world in lowercase")
        XCTAssertTrue(result.contains("case:lower"), "got: \(result)")
    }

    func testCaseTitleCase() {
        let result = ClipboardStyle.describe("Hello World From Swift")
        XCTAssertTrue(result.contains("case:title"), "got: \(result)")
    }

    func testCaseMixed() {
        let result = ClipboardStyle.describe("helloWorld and mixedCase")
        XCTAssertTrue(result.contains("case:mixed"), "got: \(result)")
    }

    func testCaseNoneNoLetters() {
        let result = ClipboardStyle.describe("123 456 !!! @@@")
        XCTAssertTrue(result.contains("case:none"), "got: \(result)")
    }
}
