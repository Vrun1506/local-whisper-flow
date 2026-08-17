import Foundation

struct Transcript: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date

    init(text: String, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.date = date
    }
}

/// The last few dictations, kept on disk.
///
/// Doubles as the safety net for the cases where delivery fails — Secure Input,
/// a missing Accessibility grant, a target app that swallows the paste. The
/// text is always recoverable from the menu even when it never reached the
/// cursor.
final class TranscriptStore {
    static let shared = TranscriptStore()

    private let limit = 50
    private let fileURL = Settings.supportDirectory.appendingPathComponent("history.json")
    private(set) var transcripts: [Transcript] = []

    private init() {
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcripts.insert(Transcript(text: trimmed), at: 0)
        if transcripts.count > limit {
            transcripts.removeLast(transcripts.count - limit)
        }
        save()
    }

    func clear() {
        transcripts.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Transcript].self, from: data)
        else { return }
        transcripts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(transcripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Everything you have dictated sits in this file. Default 0644 would let
        // any other account on the Mac read it; owner-only is the honest default
        // for something this personal.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }
}
