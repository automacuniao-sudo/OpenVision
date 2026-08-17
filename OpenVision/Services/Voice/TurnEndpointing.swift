// OpenVision - TurnEndpointing.swift
// Adaptive end-of-turn timing for Brazilian Portuguese voice commands.

import Foundation

/// Pure, dependency-free endpointing heuristics.
///
/// A single 4-second silence timeout makes every command feel slow. A single very short timeout,
/// however, cuts users off when they pause mid-sentence. This helper keeps a short window when the
/// transcript reads complete and a longer one when it still appears to be unfinished.
enum TurnEndpointing {
    /// Normal finished phrase: fast enough to feel conversational, long enough to ride through
    /// small gaps between words and late Apple Speech partials.
    static let completeTimeout: TimeInterval = 0.9

    /// Incomplete phrase / filler / very short fragment: give the speaker room to continue.
    static let incompleteTimeout: TimeInterval = 3.0

    static let minimumWordsForFastCommit = 2

    /// Portuguese words which strongly suggest the sentence is still waiting for a complement.
    /// Deliberately conservative: a false positive only adds latency, but a false negative can cut
    /// the user's sentence in half.
    private static let danglingWords: Set<String> = [
        // articles / determiners
        "o", "a", "os", "as", "um", "uma", "uns", "umas", "meu", "minha", "meus", "minhas",
        "seu", "sua", "seus", "suas", "nosso", "nossa", "nossos", "nossas", "esse", "essa",
        "esses", "essas", "este", "esta", "estes", "estas", "aquele", "aquela", "aqueles", "aquelas",

        // prepositions / contractions
        "de", "do", "da", "dos", "das", "em", "no", "na", "nos", "nas", "para", "pra", "pro",
        "por", "com", "sem", "sobre", "entre", "até", "desde", "contra", "após", "antes", "durante",

        // conjunctions / connectors
        "e", "ou", "mas", "porque", "que", "se", "quando", "enquanto", "embora", "como",

        // auxiliaries / modal verbs which commonly dangle
        "é", "está", "estão", "era", "foi", "ser", "estar", "tem", "tenho", "ter", "vai", "vou",
        "pode", "posso", "deve", "devo", "quero", "quer", "preciso", "precisa", "consegue", "consigo",

        // interrogatives at the end normally mean the question is unfinished
        "quem", "qual", "quais", "onde", "quando", "como", "quanto", "quantos", "quantas",

        // common command verbs which usually need an object
        "fale", "fala", "explique", "explica", "pesquise", "pesquisa", "procure", "procura", "diga",
        "mostre", "mostra", "crie", "cria", "adicione", "adicione", "mande", "envie", "abra", "coloque"
    ]

    private static let fillers: Set<String> = [
        "ah", "ahn", "hã", "hum", "hmm", "hm", "é", "tipo", "bom", "então", "assim", "né"
    ]

    static func silenceTimeout(for transcript: String) -> TimeInterval {
        isLikelyComplete(transcript) ? completeTimeout : incompleteTimeout
    }

    static func isLikelyComplete(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Terminal punctuation emitted by Speech is a strong signal that the turn is complete.
        if let last = trimmed.last, last == "." || last == "?" || last == "!" {
            return true
        }

        let words = tokenize(trimmed)
        guard words.count >= minimumWordsForFastCommit, let last = words.last else { return false }
        if fillers.contains(last) { return false }
        if danglingWords.contains(last) { return false }
        return true
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map {
                String($0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}…-–—")))
            }
            .filter { !$0.isEmpty }
    }
}
