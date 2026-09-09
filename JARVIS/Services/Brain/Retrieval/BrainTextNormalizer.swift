import Foundation

enum BrainTextNormalizer {
    private static let stopWords: Set<String> = [
        "a", "o", "as", "os", "de", "do", "da", "dos", "das",
        "e", "é", "em", "no", "na", "nos", "nas", "um", "uma",
        "meu", "minha", "qual"
    ]

    static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "pt_BR")
            )
            .lowercased()
    }

    static func tokens(_ text: String) -> Set<String> {
        let normalizedText = normalized(text)
        let components = normalizedText.components(separatedBy: CharacterSet.alphanumerics.inverted)

        return Set(
            components.filter { token in
                !token.isEmpty && !stopWords.contains(token)
            }
        )
    }
}
