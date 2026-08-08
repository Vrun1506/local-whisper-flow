import AVFoundation

/// A speech-to-text backend.
///
/// The lifecycle is: `prepare()` once when the engine is selected, then
/// `beginUtterance()` / `feed()` / `finishUtterance()` per hold of the hotkey.
///
/// Backends differ in when they can produce text. The Apple analyzer streams
/// partial results while you speak; whisper.cpp sees the whole utterance at
/// once and returns nothing until you release. `onPartial` therefore fires
/// continuously for one and never for the other, and the HUD copes with both.
protocol TranscriptionEngine: AnyObject {
    var displayName: String { get }

    /// Audio format `feed(_:)` expects. Only valid after `prepare()`.
    var audioFormat: AVAudioFormat { get }

    /// Live preview text, main-thread. Optional for a backend to ever call.
    var onPartial: ((String) -> Void)? { get set }

    /// Download models, warm caches. `status` reports human-readable progress.
    func prepare(status: @escaping (String) -> Void) async throws

    func beginUtterance() async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Returns the finished transcript, already whitespace-normalised.
    func finishUtterance() async throws -> String
    /// Abandon the in-flight utterance without transcribing (short taps).
    func cancelUtterance() async

    /// Release models and memory. Called when switching engines.
    func teardown() async
}

extension String {
    /// Transcribers emit leading/trailing spaces and occasional double spaces
    /// between segment joins; neither is wanted at a text cursor.
    var normalizedTranscript: String {
        split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
