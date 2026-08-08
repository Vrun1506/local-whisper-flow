import AVFoundation
import Foundation
import Speech

/// macOS 26's on-device `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// Entirely offline and free: the system downloads a per-locale model once via
/// `AssetInventory` and reuses it. Streams volatile (provisional) results while
/// you speak and firms them up into final ones as context arrives.
///
/// The whole framework is new in macOS 26, hence the availability gate — on
/// anything older the app runs Whisper only.
@available(macOS 26, *)
final class AppleSpeechEngine: TranscriptionEngine {

    enum EngineError: LocalizedError {
        case localeUnsupported(Locale)
        case notPrepared
        case assetInstallFailed

        var errorDescription: String? {
            switch self {
            case let .localeUnsupported(locale):
                return "Apple's on-device transcription doesn't support \(locale.identifier)."
            case .notPrepared:
                return "Speech engine was used before it finished preparing."
            case .assetInstallFailed:
                return "Could not install the on-device speech model."
            }
        }
    }

    let displayName = "Apple Speech"
    var onPartial: ((String) -> Void)?

    private var resolvedLocale: Locale?
    private var cachedFormat: AVAudioFormat?

    // Recreated per utterance: `results` is a one-shot sequence, so reusing a
    // transcriber across holds would leave the second hold with a dead stream.
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text the analyzer has committed to.
    private var finalText = ""
    /// Provisional tail that may still be rewritten; shown in the HUD but
    /// discarded in favour of the final version.
    private var volatileText = ""

    var audioFormat: AVAudioFormat {
        // 16 kHz mono float is what the analyzer reports on every Apple silicon
        // Mac; the fallback only matters if prepare() was skipped.
        cachedFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000,
                                      channels: 1,
                                      interleaved: false)!
    }

    // MARK: Preparation

    func prepare(status: @escaping (String) -> Void) async throws {
        let requested = Locale.current
        var match = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        if match == nil {
            // Fall back to US English rather than refusing to run on an
            // unusual system locale.
            match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let supported = match else {
            throw EngineError.localeUnsupported(requested)
        }
        resolvedLocale = supported

        let probe = makeTranscriber(locale: supported)

        // The model is a system asset, not something we ship. First run on a
        // fresh machine downloads it; later runs are a no-op.
        let inventoryStatus = await AssetInventory.status(forModules: [probe])
        if inventoryStatus != .installed {
            status("Downloading speech model…")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    // This is a multi-hundred-megabyte system asset. Poll its
                    // Progress so a slow first run looks like a slow first run
                    // rather than a hang.
                    let progress = request.progress
                    let reporter = Task {
                        while !Task.isCancelled {
                            status("Downloading speech model… \(Int(progress.fractionCompleted * 100))%")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    defer { reporter.cancel() }
                    try await request.downloadAndInstall()
                }
            } catch {
                throw EngineError.assetInstallFailed
            }
        }

        // Without a reservation the system may evict the model to reclaim space.
        _ = try? await AssetInventory.reserve(locale: supported)

        status("Resolving audio format…")
        cachedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])

        // Pull the model into the system cache now so the first real hold
        // doesn't pay a cold-start delay mid-sentence. Best-effort only, and
        // time-boxed: a warm-up that hangs must not block the app from starting.
        status("Warming up…")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [cachedFormat] in
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [probe])
                try? await analyzer.prepareToAnalyze(in: cachedFormat)
                continuation.finish()
                await analyzer.cancelAndFinishNow()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
            }
            await group.next()
            group.cancelAll()
        }

        status("Ready")
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // .progressiveTranscription enables volatileResults, which is what makes
        // text appear in the HUD while you're still talking.
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    // MARK: Utterance

    func beginUtterance() async throws {
        guard let resolvedLocale else { throw EngineError.notPrepared }

        finalText = ""
        volatileText = ""

        let transcriber = makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    let preview = (self.finalText + self.volatileText).normalizedTranscript
                    // Dispatch rather than `await MainActor.run`: awaiting the
                    // main actor here would deadlock any caller that drives this
                    // engine while blocking the main thread, and would stall the
                    // results loop — which in turn stalls finalization. async
                    // still preserves ordering, so the preview never goes
                    // backwards.
                    let handler = self.onPartial
                    DispatchQueue.main.async { handler?(preview) }
                }
            } catch {
                // A failed stream just means no more partials; finishUtterance
                // still returns whatever was committed before the error.
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finishUtterance() async throws -> String {
        // End the input first: finalizeAndFinishThroughEndOfInput waits for the
        // sequence to terminate before it will flush the decoder.
        inputContinuation?.finish()
        inputContinuation = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value

        let result = (finalText + volatileText).normalizedTranscript
        resetUtterance()
        return result
    }

    func cancelUtterance() async {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resetUtterance()
    }

    private func resetUtterance() {
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        finalText = ""
        volatileText = ""
    }

    func teardown() async {
        await cancelUtterance()
        if let resolvedLocale {
            _ = await AssetInventory.release(reservedLocale: resolvedLocale)
        }
        resolvedLocale = nil
        cachedFormat = nil
    }
}
