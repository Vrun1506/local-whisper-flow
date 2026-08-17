import CryptoKit
import Foundation

enum WhisperModel {
    /// The q5_0 quantisation of large-v3-turbo: 574 MB against 1.6 GB for the
    /// f16 original, for a negligible accuracy difference. Worth it in both
    /// download size and resident memory.
    static let fileName = "ggml-large-v3-turbo-q5_0.bin"

    static let url = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!

    static let approximateBytes: Int64 = 574_000_000

    /// SHA-256 of the published file, as reported by Hugging Face's
    /// `x-linked-etag` (which is the LFS object hash for this repo).
    ///
    /// Checked before the file is handed to whisper.cpp. TLS already rules out
    /// a tampered response in transit; this covers the rest — a truncated
    /// download, a corrupted disk write, a proxy that served something else, or
    /// the upstream file being replaced. ggml parses this blob in C, so
    /// "definitely the bytes we expected" is worth the few seconds it costs.
    static let sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

    /// Streams the file rather than loading 574 MB into memory to hash it.
    static func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One-shot background download with progress, straight to its final path.
///
/// `URLSessionDownloadTask` rather than `URLSession.bytes` because the latter
/// hands back an `AsyncSequence<UInt8>`, which is unusably slow over 574 MB.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case moveFailed(String)
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case let .badResponse(code): return "Model download failed (HTTP \(code))."
            case let .moveFailed(detail): return "Could not save the model: \(detail)"
            case let .checksumMismatch(expected, actual):
                return "Downloaded model does not match its expected checksum "
                     + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…). "
                     + "It has been discarded; try again."
            }
        }
    }

    private var destination: URL!
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    /// Resolves once the file is in place. Returns immediately if it already is.
    func download(to destination: URL, progress: @escaping (Double) -> Void) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }

        self.destination = destination
        self.progressHandler = progress

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: WhisperModel.url).resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Hugging Face doesn't always send Content-Length on redirected CDN
        // responses, so fall back to the known approximate size.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : WhisperModel.approximateBytes
        progressHandler?(min(1.0, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let code = response?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            finish(.failure(DownloadError.badResponse(code)))
            return
        }

        do {
            // Verify before the file is anywhere the engine would load it from.
            let actual = try WhisperModel.sha256OfFile(at: location)
            guard actual == WhisperModel.sha256 else {
                try? FileManager.default.removeItem(at: location)
                finish(.failure(DownloadError.checksumMismatch(expected: WhisperModel.sha256,
                                                              actual: actual)))
                return
            }

            // The temp file is deleted the moment this delegate returns, so the
            // move has to happen here rather than in the continuation.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(DownloadError.moveFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
