// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// Keep Google Search grounding OUT of the Gemini Live session so voice remains compatible with
// the project's free-tier key. Current information is fetched by a short, separate generateContent
// request and returned to the Live model as a normal native-tool result.

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

    /// Flash-Lite is enough for search-result synthesis and is normally lower-latency / less
    /// capacity-constrained. Stable Flash is the fallback if Lite has a transient service issue.
    /// Both officially support Google Search grounding.
    private static let searchModels = ["gemini-2.5-flash-lite", "gemini-2.5-flash"]
    private static let transientHTTPStatus: Set<Int> = [429, 500, 502, 503, 504]

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSearchError.invalidQuery
        }

        let apiKey = await MainActor.run {
            SettingsManager.shared.settings.geminiAPIKey
        }
        guard !apiKey.isEmpty else { throw WebSearchError.missingAPIKey }

        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let prompt = """
        Pesquise na web e responda à pergunta abaixo usando informações atuais e verificáveis.
        Data/hora local aproximada do usuário: \(now)
        Pergunta: \(query)

        Responda em português brasileiro, de forma objetiva. Priorize a informação mais recente e
        não invente fatos caso a pesquisa não confirme a resposta. Não explique o processo de busca.
        """

        var lastError: Error = WebSearchError.invalidResponse

        // Two quick tries on Flash-Lite, then one fallback try on Flash. Direct REST requests do not
        // get the SDK's automatic retry policy, so without this a single 503/timeout surfaced to the
        // user as "não consegui pesquisar" even though the service recovered seconds later.
        for (modelIndex, model) in Self.searchModels.enumerated() {
            let attempts = modelIndex == 0 ? 2 : 1
            for attempt in 1...attempts {
                do {
                    return try await performSearch(model: model, apiKey: apiKey, prompt: prompt, attempt: attempt)
                } catch {
                    lastError = error
                    let transient = Self.isTransient(error)
                    await MainActor.run {
                        DiagnosticLogger.shared.log(
                            "WebSearch",
                            "Attempt failed model=\(model) attempt=\(attempt)/\(attempts) transient=\(transient): \(error.localizedDescription)"
                        )
                    }

                    // Permanent errors (bad key, unsupported request, permission) should be surfaced
                    // immediately. Retrying them only adds latency and hides configuration problems.
                    if !transient { throw error }

                    let isLastOverallAttempt = modelIndex == Self.searchModels.count - 1 && attempt == attempts
                    if !isLastOverallAttempt {
                        let delayMs: UInt64 = attempt == 1 ? 650 : 1_200
                        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    }
                }
            }
        }

        throw lastError
    }

    private func performSearch(model: String, apiKey: String, prompt: String, attempt: Int) async throws -> String {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw WebSearchError.invalidEndpoint }

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "tools": [["googleSearch": [:] as [String: Any]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 1024
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Searching current web model=\(model) attempt=\(attempt)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw WebSearchError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.extractAPIError(from: data) ?? "HTTP \(http.statusCode)"
            throw WebSearchError.apiStatus(http.statusCode, message)
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
            DiagnosticLogger.shared.log("WebSearch", "Search completed model=\(model)")
        }
        return text
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let webError = error as? WebSearchError else { return true }
        switch webError {
        case .transport:
            return true
        case .apiStatus(let status, _):
            return transientHTTPStatus.contains(status)
        default:
            return false
        }
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
    case transport(String)
    case apiStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "A pesquisa precisa de uma pergunta."
        case .missingAPIKey: return "A chave do Gemini não está configurada."
        case .invalidEndpoint: return "Não foi possível montar o endpoint de pesquisa."
        case .invalidResponse: return "A pesquisa retornou uma resposta inválida."
        case .emptyResult: return "A pesquisa não encontrou uma resposta utilizável."
        case .transport(let message): return "Falha de rede na pesquisa: \(message)"
        case .apiStatus(let status, let message): return "Falha na pesquisa (HTTP \(status)): \(message)"
        }
    }
}
