// JARVIS - WebSearchEvidenceStore.swift
// Stores provenance of the most recent web_search so follow-ups can cite real URLs instead of hallucinating.

import Foundation

@MainActor
final class WebSearchEvidenceStore {
    static let shared = WebSearchEvidenceStore()

    struct Source: Equatable {
        let title: String
        let url: String
    }

    private(set) var query: String = ""
    private(set) var provider: String = ""
    private(set) var sources: [Source] = []
    private(set) var recordedAt: Date?

    private init() {}

    func record(query: String, provider: String, result: String) {
        self.query = query
        self.provider = provider
        self.recordedAt = Date()

        let lines = result.components(separatedBy: .newlines)
        var collected: [Source] = []
        var seen = Set<String>()

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            let prefixes = ["fonte:", "fonte_url:", "source:", "source_url:"]
            guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { continue }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = firstHTTPURL(in: value), seen.insert(url).inserted else { continue }

            var title = "Fonte"
            if index > 0 {
                let previous = lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !previous.isEmpty, !previous.lowercased().hasPrefix("fonte") {
                    title = String(previous.prefix(180))
                }
            }
            collected.append(Source(title: title, url: url))
            if collected.count >= 10 { break }
        }
        sources = collected
    }

    func rendered() -> String {
        guard recordedAt != nil else {
            return "Nenhuma pesquisa web foi executada nesta conversa ainda. Não invente uma fonte ou link."
        }
        var lines = [
            "PROVENIÊNCIA DA ÚLTIMA PESQUISA WEB:",
            "consulta = \(query)",
            "provedor = \(provider)"
        ]
        if sources.isEmpty {
            lines.append("URLs verificáveis = nenhuma extraída")
            lines.append("REGRA: diga que não há um link verificável disponível; não invente site, domínio ou URL.")
        } else {
            for (index, source) in sources.enumerated() {
                lines.append("\(index + 1). \(source.title)")
                lines.append("URL: \(source.url)")
            }
            lines.append("REGRA: cite/copiei somente URLs listadas acima. Nunca atribua a pesquisa a outro site.")
        }
        return lines.joined(separator: "\n")
    }

    private func firstHTTPURL(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s<>]+"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]}>\"'"))
    }
}

struct LastSearchSourcesTool: NativeTool {
    let name = "last_search_sources"
    let description = "Returns the REAL provider and URLs from the most recent web_search. MUST call when the user asks 'qual a fonte?', 'de onde tirou?', 'qual o link?', wants to verify a search, or asks to copy the source link. Never name/copy a source from memory."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "additionalProperties": false
    ]

    func execute(args: [String: Any]) async throws -> String {
        await MainActor.run { WebSearchEvidenceStore.shared.rendered() }
    }
}
