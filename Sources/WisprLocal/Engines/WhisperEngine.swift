import AVFoundation
import CWhisper
import Foundation

/// Minimal mutex around a value. `Synchronization.Mutex` would be tidier but
/// needs macOS 15; this keeps the deployment floor at Ventura. Locking happens
/// inside a synchronous method, so it is safe to call from async code.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// OpenAI Whisper (large-v3-turbo) running locally through Homebrew's
/// `libwhisper`, with Metal acceleration.
///
/// The context is loaded once and held for the process lifetime. That is the
/// entire reason for linking the library instead of shelling out to
/// `whisper-cli`: reloading a 574 MB model per utterance would add well over a
/// second to every single dictation.
///
/// Unlike the Apple engine there are no partial results — Whisper needs the
/// whole utterance before it decodes anything.
final class WhisperEngine: TranscriptionEngine {

    enum EngineError: LocalizedError {
        case modelMissing(URL)
        case contextInitFailed
        case decodeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .modelMissing(url):
                return "Whisper model not found at \(url.path)."
            case .contextInitFailed:
                return "Could not load the Whisper model. It may be corrupt — delete it and let it re-download."
            case let .decodeFailed(code):
                return "Whisper failed to transcribe (code \(code))."
            }
        }
    }

    let displayName = "Whisper large-v3-turbo"
    var onPartial: ((String) -> Void)?

    /// Whisper is hard-wired to 16 kHz mono float32.
    private static let sampleRate = 16_000.0
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false)!

    /// `whisper_context *` is a plain C pointer with no Swift-visible
    /// thread-safety story. It's only ever touched by one decode at a time, so
    /// hand-wave it across isolation boundaries rather than serialising through
    /// an actor we'd immediately have to block on.
    private struct ContextBox: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private var context: OpaquePointer?

    /// Written from the audio thread, read from the decode task.
    private let samples = Locked<[Float]>([])

    deinit {
        if let context { whisper_free(context) }
    }

    // MARK: Preparation

    func prepare(status: @escaping (String) -> Void) async throws {
        guard context == nil else { return }

        let modelURL = Settings.shared.whisperModelPath
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            status("Downloading Whisper model (574 MB)…")
            let downloader = ModelDownloader()
            var lastPercent = -1
            try await downloader.download(to: modelURL) { fraction in
                // Report only on change: the delegate fires per chunk, which is
                // thousands of callbacks over 574 MB.
                let percent = Int(fraction * 100)
                guard percent != lastPercent else { return }
                lastPercent = percent
                status("Downloading Whisper model… \(percent)%")
            }
        }

        status("Loading model…")
        // Loading pulls 574 MB off disk and into Metal buffers; keep it off the
        // main thread or the menu bar freezes for a second or two.
        let path = modelURL.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> ContextBox? in
            // whisper.cpp and ggml narrate backend discovery and model loading
            // to stderr. Fine for a CLI, just noise for a menu bar app. Silence
            // them before load_all, which is itself chatty.
            whisper_log_set({ _, _, _ in }, nil)
            ggml_log_set({ _, _, _ in }, nil)

            // ggml ships its compute backends (Metal, CPU) as separate loadable
            // modules under libexec. Without this, whisper_init aborts inside
            // make_buft_list with GGML_ASSERT(device) — there is no device to
            // find. Idempotent, so calling it on every prepare() is fine.
            ggml_backend_load_all()

            var params = whisper_context_default_params()
            params.use_gpu = true       // Metal on Apple silicon
            params.flash_attn = true
            guard let pointer = path.withCString({ whisper_init_from_file_with_params($0, params) })
            else { return nil }
            return ContextBox(pointer: pointer)
        }.value

        guard let loaded else { throw EngineError.contextInitFailed }
        context = loaded.pointer
        status("Ready")
    }

    // MARK: Utterance

    func beginUtterance() async throws {
        guard context != nil else {
            throw EngineError.modelMissing(Settings.shared.whisperModelPath)
        }
        samples.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let incoming = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        samples.withLock { $0.append(contentsOf: incoming) }
    }

    func finishUtterance() async throws -> String {
        guard let context else {
            throw EngineError.modelMissing(Settings.shared.whisperModelPath)
        }

        var audio = samples.withLock { current -> [Float] in
            let copy = current
            current.removeAll(keepingCapacity: true)
            return copy
        }

        // whisper.cpp rejects clips shorter than one second outright, and short
        // holds are common. Pad with silence rather than dropping the audio.
        let minimum = Int(Self.sampleRate)
        if audio.count < minimum {
            guard !audio.isEmpty else { return "" }
            audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
        }

        let threads = Int32(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let box = ContextBox(pointer: context)
        let clip = audio

        return try await Task.detached(priority: .userInitiated) { () -> String in
            let context = box.pointer
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = threads
            params.no_timestamps = true
            params.print_progress = false
            params.print_realtime = false
            params.print_special = false
            params.print_timestamps = false
            params.translate = false
            params.suppress_blank = true
            // Each hold is independent; carrying context across them lets a
            // previous sentence bias the next one.
            params.no_context = true

            // `language` is borrowed for the duration of the call, so the C
            // string has to outlive whisper_full — hence the nested withCString.
            let status: Int32 = "en".withCString { lang in
                params.language = lang
                return clip.withUnsafeBufferPointer { buf in
                    whisper_full(context, params, buf.baseAddress, Int32(buf.count))
                }
            }
            guard status == 0 else { throw EngineError.decodeFailed(status) }

            var pieces: [String] = []
            for i in 0..<whisper_full_n_segments(context) {
                if let cString = whisper_full_get_segment_text(context, i) {
                    pieces.append(String(cString: cString))
                }
            }
            return pieces.joined(separator: " ").normalizedTranscript
        }.value
    }

    func cancelUtterance() async {
        samples.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func teardown() async {
        await cancelUtterance()
        if let context {
            whisper_free(context)
            self.context = nil
        }
    }
}
