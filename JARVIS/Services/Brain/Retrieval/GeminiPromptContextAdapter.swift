import Foundation

enum GeminiPromptContextAdapter {
    static func makePrompt(basePrompt: String, brainContext: String?) -> String {
        guard let brainContext else { return basePrompt }

        let trimmed = brainContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return basePrompt }

        return basePrompt + "\n\n" + trimmed
    }
}
