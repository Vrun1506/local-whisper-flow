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
    // Ventura is the floor. The Whisper engine works throughout; the Apple
    // engine is gated to macOS 26 at runtime, since SpeechAnalyzer ships there.
    platforms: [.macOS(.v13)],
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
