import Foundation

enum WhisperModel {
    /// The q5_0 quantisation of large-v3-turbo: 574 MB against 1.6 GB for the
    /// f16 original, for a negligible accuracy difference. Worth it in both
    /// download size and resident memory.
    static let fileName = "ggml-large-v3-turbo-q5_0.bin"

    static let url = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!

    static let approximateBytes: Int64 = 574_000_000
}

/// One-shot background download with progress, straight to its final path.
///
/// `URLSessionDownloadTask` rather than `URLSession.bytes` because the latter
/// hands back an `AsyncSequence<UInt8>`, which is unusably slow over 574 MB.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case let .badResponse(code): return "Model download failed (HTTP \(code))."
            case let .moveFailed(detail): return "Could not save the model: \(detail)"
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
