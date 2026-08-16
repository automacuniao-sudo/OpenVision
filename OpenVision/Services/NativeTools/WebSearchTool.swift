// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// Gemini 3 Live can technically combine Google Search with function calling, but Google Search
// grounding is not available on the Gemini 3 free tier. Advertising googleSearch directly in the
// Live session therefore prevents a free-tier session from completing setup. This tool keeps the
// Live voice session free-tier compatible, then performs current-information lookup separately via
// gemini-2.5-flash + Google Search grounding, which still supports search grounding on the free tier.

import Foundation

struct WebSearchTool: NativeTool {
    let name = "web_search"
    let description = "Search the current internet for up-to-date information. Use this for explicit requests to search/pesquisar na internet and for time-sensitive facts such as sports schedules/results, current news, weather, prices, releases, current office-holders, or recent events."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "The concise search question to answer using current web information."
            ]
        ],
        "required": ["query"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSearchError.invalidQuery
        }

        let apiKey = await MainActor.run {
            SettingsManager.shared.settings.geminiAPIKey
        }
        guard !apiKey.isEmpty else { throw WebSearchError.missingAPIKey }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw WebSearchError.invalidEndpoint }

        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let prompt = """
        Pesquise na web e responda à pergunta abaixo usando informações atuais e verificáveis.
        Data/hora local aproximada do usuário: \(now)
        Pergunta: \(query)

        Responda em português brasileiro, de forma objetiva. Priorize a informação mais recente e
        não invente fatos caso a pesquisa não confirme a resposta. Não explique o processo de busca.
        """

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "tools": [["googleSearch": [:] as [String: Any]]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 1024
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Searching current web via Gemini 2.5 Flash")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractAPIError(from: data) ?? "HTTP \(http.statusCode)"
            await MainActor.run {
                DiagnosticLogger.shared.log("WebSearch", "Search failed: \(message)")
            }
            throw WebSearchError.api(message)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw WebSearchError.invalidResponse
        }

        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw WebSearchError.emptyResult }

        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Search completed")
        }
        return text
    }

    private static func extractAPIError(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

private enum WebSearchError: LocalizedError {
    case invalidQuery
    case missingAPIKey
    case invalidEndpoint
    case invalidResponse
    case emptyResult
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "A pesquisa precisa de uma pergunta."
        case .missingAPIKey: return "A chave do Gemini não está configurada."
        case .invalidEndpoint: return "Não foi possível montar o endpoint de pesquisa."
        case .invalidResponse: return "A pesquisa retornou uma resposta inválida."
        case .emptyResult: return "A pesquisa não encontrou uma resposta utilizável."
        case .api(let message): return "Falha na pesquisa: \(message)"
        }
    }
}
