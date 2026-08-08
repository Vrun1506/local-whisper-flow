import Foundation

enum EngineKind: String, CaseIterable {
    case apple
    case whisper

    var displayName: String {
        switch self {
        case .apple:   return "Apple (on-device, fastest)"
        case .whisper: return "Whisper large-v3-turbo (most accurate)"
        }
    }

    /// SpeechAnalyzer ships in macOS 26. Older systems get Whisper only.
    var isAvailable: Bool {
        switch self {
        case .apple:
            if #available(macOS 26, *) { return true }
            return false
        case .whisper:
            return true
        }
    }

    static var available: [EngineKind] { allCases.filter(\.isAvailable) }

    /// Best engine this machine can actually run.
    static var preferredDefault: EngineKind {
        available.contains(.apple) ? .apple : .whisper
    }

    /// Builds the backend, falling back when the stored choice isn't supported
    /// (an older macOS, or settings carried over from a newer machine).
    func makeEngine() -> TranscriptionEngine {
        if self == .apple, #available(macOS 26, *) {
            return AppleSpeechEngine()
        }
        return WhisperEngine()
    }
}

enum OutputMode: String, CaseIterable {
    /// Put the text on the pasteboard and synthesize ⌘V. Fast, but momentarily
    /// borrows the clipboard.
    case paste
    /// Synthesize the characters directly. Slower, never touches the clipboard,
    /// and works in a few apps that ignore synthetic paste.
    case type

    var displayName: String {
        switch self {
        case .paste: return "Paste (⌘V)"
        case .type:  return "Type character by character"
        }
    }
}

/// UserDefaults-backed preferences. Small enough that a struct of computed
/// properties beats any real persistence layer.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let engine = "engine"
        static let outputMode = "outputMode"
        static let playSounds = "playSounds"
        static let removeFillers = "removeFillers"
        static let whisperModelPath = "whisperModelPath"
    }

    private init() {
        defaults.register(defaults: [
            Key.engine: EngineKind.preferredDefault.rawValue,
            Key.outputMode: OutputMode.paste.rawValue,
            Key.playSounds: true,
            Key.removeFillers: true,
        ])
    }

    /// Strip "um"/"uh" and stutters before pasting. Off means verbatim.
    var removeFillers: Bool {
        get { defaults.bool(forKey: Key.removeFillers) }
        set { defaults.set(newValue, forKey: Key.removeFillers) }
    }

    var engine: EngineKind {
        get {
            let stored = EngineKind(rawValue: defaults.string(forKey: Key.engine) ?? "")
            // Never hand back an engine this machine can't run.
            guard let stored, stored.isAvailable else { return .preferredDefault }
            return stored
        }
        set { defaults.set(newValue.rawValue, forKey: Key.engine) }
    }

    var outputMode: OutputMode {
        get { OutputMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.outputMode) }
    }

    var playSounds: Bool {
        get { defaults.bool(forKey: Key.playSounds) }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    /// Where the ggml model lives. Defaults into Application Support so it
    /// survives rebuilds of the app bundle.
    ///
    /// `WISPRLOCAL_MODEL` overrides it — useful for testing against a small
    /// model, or for pointing at a ggml file you already have rather than
    /// downloading another copy.
    var whisperModelPath: URL {
        if let env = ProcessInfo.processInfo.environment["WISPRLOCAL_MODEL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let custom = defaults.string(forKey: Key.whisperModelPath) {
            return URL(fileURLWithPath: custom)
        }
        return Self.supportDirectory.appendingPathComponent(WhisperModel.fileName)
    }

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WisprLocal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
