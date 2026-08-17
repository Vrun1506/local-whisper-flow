// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Homebrew lives at /opt/homebrew on Apple silicon and /usr/local on Intel.
// Detect rather than hard-code, so the package builds on both.
let brewPrefix: String = {
    if let override = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] { return override }
    return FileManager.default.fileExists(atPath: "/opt/homebrew/lib") ? "/opt/homebrew" : "/usr/local"
}()

let package = Package(
    name: "WisprLocal",
    // Tahoe is the floor, because SpeechAnalyzer ships there and that is the
    // only configuration this is tested on. The Apple engine keeps its runtime
    // #available gate and Whisper still works without it, so lowering this is a
    // one-line change for anyone who wants to try an older system — but it
    // would have to move in lockstep with LSMinimumSystemVersion in Info.plist.
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),

        .executableTarget(
            name: "WisprLocal",
            dependencies: ["CWhisper"],
            path: "Sources/WisprLocal",
            swiftSettings: [
                // -Xcc so the clang importer can find whisper.h when it builds
                // the CWhisper module, not just when Swift compiles.
                .unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"]),
                // Audio taps and CGEventTap callbacks are inherently C-callback
                // shaped; v5 mode keeps those from becoming compile errors.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                // Homebrew's dylibs carry absolute install names, so no rpath is
                // needed — dyld resolves them directly.
                .unsafeFlags([
                    "-L\(brewPrefix)/lib",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                ]),
            ]
        ),
    ]
)
