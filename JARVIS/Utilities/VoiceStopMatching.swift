// JARVIS - VoiceStopMatching.swift
// Pure deterministic stop-command matching shared by the voice runtime and UI routing.

import Foundation

enum VoiceStopMatching {
    private static let stopPhrases = [
        "stop", "ok stop", "okay stop", "be quiet", "shut up", "silence", "quiet", "enough", "cancel",
        "pare", "parar", "silencio", "cala a boca", "fica quieto",
        "chega", "cancela", "cancelar", "cancele a resposta"
    ]

    private static let liveExitPhrases = [
        "stop", "top", "end", "exit", "disable", "close", "quit", "turn off",
        "pare", "para", "parar", "encerre", "encerrar", "saia", "sair", "desative", "desativar"
    ]

    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// A bare stop silences/cancels the current response. It deliberately rejects video/stream
    /// commands so "stop video" can be routed to the live-mode teardown instead.
    static func isBareStopCommand(_ text: String) -> Bool {
        let value = normalized(text)
        guard !value.isEmpty, !mentionsLiveVideo(value) else { return false }
        return stopPhrases.contains { phrase in
            value == phrase || value.hasPrefix(phrase + " ")
        }
    }

    /// "stop video"/"encerrar stream" exits live mode. Matching is word/phrase based rather than
    /// substring based, so ordinary words such as "desktop" can never become stop commands.
    static func isLiveVideoStopCommand(_ text: String) -> Bool {
        let value = normalized(text)
        guard mentionsLiveVideo(value) else { return false }
        let words = Set(value.split(separator: " ").map(String.init))
        return liveExitPhrases.contains { phrase in
            if phrase.contains(" ") {
                return value == phrase || value.hasPrefix(phrase + " ") || value.contains(" " + phrase + " ")
            }
            return words.contains(phrase)
        }
    }

    private static func mentionsLiveVideo(_ normalizedText: String) -> Bool {
        let words = Set(normalizedText.split(separator: " ").map(String.init))
        return words.contains("video") || words.contains("stream") || words.contains("streaming")
    }
}
