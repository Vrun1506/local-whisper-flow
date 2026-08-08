import AVFoundation

/// Microphone capture for the duration of a single hold-to-talk gesture.
///
/// The engine is started on key-press and stopped on release rather than kept
/// running, so the orange mic-in-use indicator only appears while you are
/// actually dictating.
///
/// Each backend wants audio in a different shape (the Apple analyzer picks its
/// own preferred format; whisper.cpp insists on 16 kHz mono float), so the
/// caller passes the format it wants and gets converted buffers back.
final class AudioCapture {

    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone input is available."
            case let .converterUnavailable(from, to):
                return "Cannot convert audio from \(from.sampleRate)Hz to \(to.sampleRate)Hz."
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isCapturing = false

    /// Normalised 0...1 loudness for the HUD's waveform. Called on the audio
    /// thread, so hop to main before touching UI.
    var onLevel: ((Float) -> Void)?

    // MARK: Control

    func start(outputFormat targetFormat: AVAudioFormat,
               onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isCapturing else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        // Sample-rate conversion is the common case here: the built-in mic runs
        // at 48 kHz and neither backend wants that.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable(from: inputFormat, to: targetFormat)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        self.outputFormat = targetFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.reportLevel(of: buffer)
            if let converted = self.convert(buffer) {
                onBuffer(converted)
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        outputFormat = nil
        isCapturing = false
    }

    // MARK: Conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return nil }

        // Resampling changes the frame count, so size the destination by the
        // rate ratio and leave slack for the converter's internal delay.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        // The pull-style API is required whenever sample rates differ; the
        // one-shot convert(to:from:) only handles format changes.
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if error != nil || output.frameLength == 0 { return nil }
        return output
    }

    // MARK: Level metering

    private func reportLevel(of buffer: AVAudioPCMBuffer) {
        guard let onLevel, let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frames)).squareRoot()

        // Speech sits far too low on a linear scale to animate nicely. Map dBFS
        // over a -50...0 window instead, which tracks perceived loudness.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        onLevel(level)
    }
}
