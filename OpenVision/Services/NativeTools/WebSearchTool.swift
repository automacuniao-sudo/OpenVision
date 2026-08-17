// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// IMPORTANT: this tool intentionally delegates to WebSearchService so Settings > Web Search is
// the source of truth. Tavily is used when the user configured a key; otherwise the existing
// keyless DuckDuckGo pipeline is used. Gemini Live only receives the returned findings.

import Foundation

struct WebSearchTool: NativeTool {
    let name = "web_search"
    let description = "Search the current internet for up-to-date information using the provider configured in Settings > Web Search. Use for explicit pesquisar/buscar requests and time-sensitive facts such as sports scores/schedules, news, weather, prices, releases, current office-holders, or recent events. When the request uses relative dates such as hoje/ontem/amanhã, include the corresponding absolute date in the query when possible."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "A concise web-search query. Include team/person/topic plus an absolute date for time-sensitive questions when known."
            ]
        ],
        "required": ["query"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let rawQuery = args["query"] as? String else { throw WebSearchError.invalidQuery }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw WebSearchError.invalidQuery }

        let provider = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "DuckDuckGo"
                : "Tavily→DuckDuckGo"
        }
        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Searching provider=\(provider)")
        }

        let result = await WebSearchService.search(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else {
            await MainActor.run {
                DiagnosticLogger.shared.log("WebSearch", "No usable results provider=\(provider)")
            }
            throw WebSearchError.emptyResult(provider)
        }

        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Search completed provider=\(provider) chars=\(result.count)")
        }
        return result
    }
}

private enum WebSearchError: LocalizedError {
    case invalidQuery
    case emptyResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "A pesquisa precisa de uma pergunta."
        case .emptyResult(let provider):
            return "A pesquisa via \(provider) não retornou resultados utilizáveis."
        }
    }
}
