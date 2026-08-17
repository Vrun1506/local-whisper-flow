import AVFoundation
import Foundation

/// Headless check that both engines can turn audio into text.
///
///     WisprLocal.app/Contents/MacOS/WisprLocal --selftest [file.wav]
///
/// Runs the same engine code the hotkey path uses, just fed from a file instead
/// of the microphone — so it verifies models, linkage and decoding without
/// needing any TCC permission or a working hotkey.
enum SelfTest {

    /// Ships with Homebrew's whisper-cpp. Probed rather than hard-coded, since
    /// the prefix is /opt/homebrew on Apple silicon and /usr/local on Intel.
    static let defaultSample: String = {
        let candidates = ["/opt/homebrew", "/usr/local"].map {
            "\($0)/share/whisper-cpp/jfk.wav"
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }()

    /// Filler removal is pure string work, so it gets checked directly rather
    /// than through the microphone. The false-positive cases matter more than
    /// the rest: deleting a word the speaker meant is the failure that would
    /// actually hurt.
    private static let cleanerCases: [(input: String, expected: String)] = [
        // The real transcript that prompted this feature.
        ("Hi, my name is Varun. Uh, I am using Whisper Flow, and this is all working.",
         "Hi, my name is Varun. I am using Whisper Flow, and this is all working."),

        ("Um, so I I think, uh, it works.", "So I think, it works."),
        ("uh, this works", "This works"),
        ("Let me erm check that.", "Let me check that."),
        ("Hmm. That is interesting.", "That is interesting."),

        // Must survive untouched — each contains a word the filter could
        // plausibly but wrongly strip.
        ("I like this a lot.", "I like this a lot."),
        ("You know the answer already.", "You know the answer already."),
        ("I mean what I say.", "I mean what I say."),
        ("He had had enough of it.", "He had had enough of it."),
        ("The point that that makes is fair.", "The point that that makes is fair."),
        ("No, no, I meant it.", "No, no, I meant it."),
        ("Her answer was clear.", "Her answer was clear."),
        ("Sort of a mixed result.", "Sort of a mixed result."),
    ]

    private static func runCleanerChecks() -> Int {
        print("── Filler removal ──")
        var failures = 0
        for (input, expected) in cleanerCases {
            let actual = TranscriptCleaner.clean(input)
            if actual == expected {
                print("   ok    \"\(input)\"  →  \"\(actual)\"")
            } else {
                print("   FAIL  \"\(input)\"")
                print("         expected \"\(expected)\"")
                print("         actual   \"\(actual)\"")
                failures += 1
            }
        }
        print(failures == 0 ? "   all \(cleanerCases.count) cases pass\n" : "   \(failures) failed\n")
        return failures
    }

    static func run(samplePath: String) async -> Int32 {
        let url = URL(fileURLWithPath: samplePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("No such audio file: \(url.path)\n".utf8))
            return 1
        }

        var failures = runCleanerChecks()

        print("Sample: \(url.lastPathComponent)")

        for kind in EngineKind.available {
            let engine = kind.makeEngine()
            print("\n── \(engine.displayName) ──")

            let clock = ContinuousClock()
            do {
                let prepared = try await clock.measure {
                    try await engine.prepare { print("   \($0)") }
                }
                print("   prepare: \(format(prepared))")

                // Twice, because both engines tear down and rebuild per-utterance
                // state. A second hold failing where the first worked is the
                // most likely way this breaks in real use.
                var texts: [String] = []
                for pass in 1...2 {
                    try await engine.beginUtterance()
                    let frames = try feed(url: url, into: engine)

                    var text = ""
                    let decode = try await clock.measure {
                        text = try await engine.finishUtterance()
                    }
                    print("   pass \(pass): \(format(decode))  \"\(text)\"  [\(frames) frames]")
                    texts.append(text)
                }

                if texts.contains(where: \.isEmpty) {
                    print("   RESULT: FAIL (empty transcript)")
                    failures += 1
                } else if texts[0] != texts[1] {
                    print("   RESULT: FAIL (passes disagree — per-utterance state is leaking)")
                    failures += 1
                } else {
                    print("   RESULT: ok")
                }
            } catch {
                print("   RESULT: FAIL — \(error.localizedDescription)")
                failures += 1
            }
            await engine.teardown()
        }

        print("\n\(failures == 0 ? "All engines working." : "\(failures) engine(s) failed.")")
        return failures == 0 ? 0 : 1
    }

    /// Streams the file through the same conversion the live pipeline does.
    private static func feed(url: URL, into engine: TranscriptionEngine) throws -> AVAudioFrameCount {
        let file = try AVAudioFile(forReading: url)
        let target = engine.audioFormat

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot convert sample to engine format"])
        }

        // Chunked to mimic the ~85 ms buffers the mic tap delivers, so streaming
        // engines see the same shape of input they will in real use.
        let chunkFrames: AVAudioFrameCount = 4096
        var totalOut: AVAudioFrameCount = 0

        while true {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: input, frameCount: chunkFrames)
            if input.frameLength == 0 { break }

            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }

            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if error != nil { break }
            if output.frameLength > 0 {
                engine.feed(output)
                totalOut += output.frameLength
            }
            if input.frameLength < chunkFrames { break }
        }
        return totalOut
    }

    private static func format(_ duration: Duration) -> String {
        String(format: "%.2fs", Double(duration.components.seconds)
               + Double(duration.components.attoseconds) / 1e18)
    }
}
