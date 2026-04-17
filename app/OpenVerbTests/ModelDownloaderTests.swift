import XCTest
@testable import OpenVerb

final class ModelDownloaderTests: XCTestCase {

    func testSHA256ConstantsExist() {
        XCTAssertFalse(ModelDownloader.expectedSHA256.isEmpty)
    }

    func testProgressCallbackFires() async throws {
        var progressValues: [Double] = []
        let downloader = ModelDownloader()
        downloader.onProgress = { p in progressValues.append(p) }
        downloader.simulateProgress([0.25, 0.5, 0.75, 1.0])
        XCTAssertEqual(progressValues, [0.25, 0.5, 0.75, 1.0])
    }

    func testResumeSupport() {
        let downloader = ModelDownloader()
        let request = downloader.buildResumeRequest(
            url: URL(string: "https://example.com/model.gguf")!,
            existingBytes: 1024
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1024-")
    }

    func testSHA256Verification() {
        let data = "test data".data(using: .utf8)!
        let hash = ModelDownloader.sha256(data)
        XCTAssertEqual(hash, "916f0027a575074ce72a331777c3478d6513f786a591bd892da1a577bf2335f9")
    }
}
