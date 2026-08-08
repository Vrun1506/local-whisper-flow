import Foundation

/// Strips speech disfluencies from a finished transcript.
///
/// Deliberately conservative. Deleting a word the speaker meant is far worse
/// than leaving a "um" in, so this only removes tokens that carry no lexical
/// meaning in any context. Hedges like "like", "you know", "I mean" and "sort
/// of" are *not* touched — each is a real phrase often enough that removing it
/// would silently corrupt sentences.
enum TranscriptCleaner {

    /// Non-lexical vocalisations. None of these is ever a content word, which
    /// is the bar for being on this list.
    private static let fillers: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "uhhm",
        "erm", "er", "mm", "mmm", "hmm", "hmmm", "mhm", "ah", "eh",
    ]

    /// Words that legitimately appear twice in a row ("he had had enough",
    /// "the point that that makes"). Everything else repeating immediately is
    /// treated as a stutter.
    private static let validWhenDoubled: Set<String> = ["had", "that"]

    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        tokens = removeFillers(from: tokens)
        tokens = collapseStutters(in: tokens)

        let joined = tokens.joined(separator: " ")
        let tidied = tidyPunctuation(joined)
        let result = capitalizeSentences(tidied)

        // If the utterance was nothing but filler there is nothing to paste,
        // and an empty string is the honest answer.
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Steps

    private static func removeFillers(from tokens: [String]) -> [String] {
        tokens.filter { token in
            // Compare on letters only, so "Um," and "uh." match the list too.
            let bare = token.lowercased().filter { $0.isLetter }
            guard !bare.isEmpty else { return true }
            guard fillers.contains(bare) else { return true }

            // Only drop it if the token really is just the filler plus
            // punctuation — never if it's glued to something meaningful.
            let nonPunctuation = token.filter { !$0.isPunctuation && !$0.isWhitespace }
            return nonPunctuation.lowercased() != bare
        }
    }

    private static func collapseStutters(in tokens: [String]) -> [String] {
        var result: [String] = []
        for token in tokens {
            let bare = token.lowercased().filter { $0.isLetter || $0.isNumber }
            let previousBare = result.last?.lowercased().filter { $0.isLetter || $0.isNumber } ?? ""

            let isStutter = !bare.isEmpty
                && bare == previousBare
                && !validWhenDoubled.contains(bare)
                // Only collapse when the earlier copy carried no punctuation:
                // "No, no, I meant it" is emphasis, not a stutter.
                && result.last?.allSatisfy { $0.isLetter || $0.isNumber } == true

            if isStutter {
                // Keep the later token — it carries any trailing punctuation.
                result.removeLast()
            }
            result.append(token)
        }
        return result
    }

    /// Removing a filler leaves debris behind: ", ," where "uh," sat between
    /// two clauses, or a leading comma where the sentence began with one.
    private static func tidyPunctuation(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"\s+"#, " "),              // collapse runs of whitespace
            (#"\s+([,.!?;:])"#, "$1"),   // no space before punctuation
            (#"([,;:])\s*(?=[,.;:!?])"#, ""),  // drop a comma that now abuts another mark
            (#"^[\s,;:]+"#, ""),         // no leading punctuation
            (#"\s+"#, " "),
        ]
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A removed leading filler can leave a lowercase word starting the
    /// sentence ("uh, this works" → "this works").
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true

        for character in text {
            if character.isLetter, capitalizeNext {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(character)
                if character == "." || character == "!" || character == "?" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }
}
