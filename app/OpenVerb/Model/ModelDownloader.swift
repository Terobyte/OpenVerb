import Foundation
import CryptoKit
import os

// ---------------------------------------------------------------------------
// ModelDownloader — downloads and verifies the GGUF model file.
//
// Progress is reported via onProgress callback and @Published properties.
// Resume is supported via URLSession native resume data (stored in resumeData).
// SHA256 is verified synchronously on the URLSession delegate queue after
// download completes — the temp file at `location` is deleted by URLSession
// after the delegate returns, so verification must happen inside the delegate.
//
// Checksums are hardcoded at compile time (pinned by build-release.sh before
// signing). The sentinel value "TBD_PIN_BEFORE_RELEASE" bypasses verification,
// which is safe for development but must never appear in a release binary.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "ModelDownloader")

final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    // -----------------------------------------------------------------------
    // Compile-time constants
    // -----------------------------------------------------------------------

    /// SHA256 of the model file. Replaced by build-release.sh before signing.
    static let expectedSHA256 = "TBD_PIN_BEFORE_RELEASE"

    static let modelURL: URL = {
        guard let url = URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf") else {
            fatalError("ModelDownloader.modelURL is malformed — update the URL string")
        }
        return url
    }()

    // -----------------------------------------------------------------------
    // Published state
    // -----------------------------------------------------------------------

    @Published var progress: Double = 0.0
    @Published var isDownloading = false
    @Published var error: String?

    // -----------------------------------------------------------------------
    // Progress callback (used in tests)
    // -----------------------------------------------------------------------

    var onProgress: ((Double) -> Void)?

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    /// Native URLSession resume data produced by cancel(). Consumed by download() on retry.
    private var resumeData: Data?
    private var destinationURL: URL

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init(modelDirectory: URL? = nil) {
        let modelDir: URL
        if let dir = modelDirectory {
            modelDir = dir
        } else {
            modelDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openverb/models")
        }
        self.destinationURL = modelDir.appendingPathComponent("gemma-4-E2B-it-Q4_K_M.gguf")
        super.init()
    }

    // -----------------------------------------------------------------------
    // download — start or resume download
    // -----------------------------------------------------------------------

    func download() async throws {
        guard !isDownloading else { return }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Invalidate any existing session: URLSession holds a strong ref to
        // its delegate until explicitly invalidated — skipping causes a leak.
        session?.invalidateAndCancel()

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        await MainActor.run { isDownloading = true; error = nil }

        // Use URLSession native resume data when retrying after cancel().
        if let data = resumeData {
            downloadTask = session?.downloadTask(withResumeData: data)
        } else {
            downloadTask = session?.downloadTask(with: Self.modelURL)
        }
        downloadTask?.resume()
    }

    // -----------------------------------------------------------------------
    // cancel — stops download, stores resume data for next download() call
    // -----------------------------------------------------------------------

    func cancel() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                self?.resumeData = data
                self?.isDownloading = false
            }
        })
    }

    // -----------------------------------------------------------------------
    // buildResumeRequest — exposed for unit testing (Range header construction)
    //
    // NOTE: Production download() uses URLSession native resume data, not Range
    // headers. This method is tested in isolation to verify header logic only.
    // -----------------------------------------------------------------------

    func buildResumeRequest(url: URL, existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    // -----------------------------------------------------------------------
    // sha256 — returns hex-encoded SHA256 of data
    // -----------------------------------------------------------------------

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // -----------------------------------------------------------------------
    // verifySHA256 — streams file in 1 MB chunks to avoid OOM on large models
    //
    // Do NOT use Data(contentsOf:) for a ~1.5 GB file — it maps the entire
    // file into RAM, causing memory pressure on 8 GB Macs.
    // -----------------------------------------------------------------------

    func verifySHA256(at url: URL) -> Bool {
        if Self.expectedSHA256 == "TBD_PIN_BEFORE_RELEASE" {
            logger.warning("SHA256 not yet pinned — skipping verification")
            return true
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        var hasher = SHA256()
        let chunkSize = 1 * 1024 * 1024  // 1 MB
        while let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        logger.info("Model SHA256: \(hash)")
        return hash == Self.expectedSHA256
    }

    // -----------------------------------------------------------------------
    // simulateProgress — test helper: fires onProgress for each value
    // -----------------------------------------------------------------------

    func simulateProgress(_ values: [Double]) {
        for v in values { onProgress?(v) }
    }

    // -----------------------------------------------------------------------
    // URLSessionDownloadDelegate
    // -----------------------------------------------------------------------

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let p = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
        Task { @MainActor in
            self.progress = p
            self.onProgress?(p)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // Verify before moving — URLSession deletes the temp file after
            // this delegate returns, so verification cannot happen later.
            guard verifySHA256(at: location) else {
                Task { @MainActor in
                    self.error = "Model integrity check failed — download may be corrupted. Please retry."
                    self.isDownloading = false
                    self.progress = 0.0
                    self.resumeData = nil
                }
                return
            }

            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: location)

            Task { @MainActor in
                self.resumeData = nil
                self.isDownloading = false
                self.progress = 1.0
            }
        } catch {
            Task { @MainActor in
                self.error = "Failed to save model: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let nsErr = error as NSError
        let savedResumeData = nsErr.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        guard nsErr.code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            if let data = savedResumeData { self.resumeData = data }
            self.error = "Download failed: \(error.localizedDescription)"
            self.isDownloading = false
        }
    }
}
