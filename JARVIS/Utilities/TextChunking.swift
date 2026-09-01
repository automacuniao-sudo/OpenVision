// OpenVision - TextChunking.swift
// MARK: - Text chunking (pure, unit-testable)

import Foundation

/// Pure text helpers for sentence-streamed TTS.
enum TextChunking {
    /// Index just past the last sentence terminator (. ! ? or newline) in `s`, or nil if none.
    /// A `.`/`!`/`?` only counts when followed by whitespace or end-of-text, so decimals like
    /// "2.5" and abbreviations don't get split mid-number.
    static func lastSentenceBoundary(in s: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var boundary: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" {
                boundary = next
            } else if terminators.contains(c) {
                let followedByBreak = next == s.endIndex || s[next] == " " || s[next] == "\n"
                if followedByBreak { boundary = next }
            }
            i = next
        }
        return boundary
    }

    /// Split `s` into speakable sentence chunks using the same boundary rules as
    /// `lastSentenceBoundary` (terminator followed by a break, or newline). Chunks are trimmed;
    /// empties dropped; text after the last terminator is included as a final chunk.
    /// Used by Kokoro TTS to synthesize per-sentence — one long reply in a single MLX pass
    /// spikes memory proportional to its length (jetsam risk next to SmolVLM2).
    static func sentences(_ s: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?"]
        var result: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            current.append(c)
            let next = s.index(after: i)
            let isBoundary = c == "\n"
                || (terminators.contains(c) && (next == s.endIndex || s[next] == " " || s[next] == "\n"))
            if isBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            i = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
