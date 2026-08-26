// JARVIS - WebSearchService.swift
// Current web search with Tavily primary and DuckDuckGo fallback.

import Foundation

enum WebSearchService {
    struct TavilyTestResult: Sendable {
        let success: Bool
        let message: String
    }

    static func search(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tavilyConfigured = await MainActor.run {
            !SettingsManager.shared.settings.tavilyAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        let timeSensitive = isTimeSensitiveQuery(trimmed)

        // Current facts get two independent retrieval lanes. DuckDuckGo starts immediately while
        // Tavily runs in parallel, so validation does not add their latencies together. Crucially,
        // Tavily's model-generated `answer` is disabled here: Gemini receives raw source evidence,
        // not a second AI's synthesis of potentially stale snippets.
        if timeSensitive {
            async let ddgTask = htmlResults(trimmed)
            let tavily: String?
            if tavilyConfigured {
                tavily = await tavilySearch(
                    trimmed,
                    searchDepth: "advanced",
                    maxResults: 7,
                    includeAnswer: false
                )
            } else {
                tavily = nil
            }
            let ddg = await ddgTask

            var blocks: [String] = []
            if let tavily, !tavily.isEmpty {
                blocks.append("EVIDÊNCIA TAVILY (resultados brutos, sem resposta sintetizada):\n\(tavily)")
            }
            if !ddg.isEmpty {
                blocks.append("EVIDÊNCIA DUCKDUCKGO (fonte independente):\n\(ddg)")
            }
            if !blocks.isEmpty {
                let combined = String(blocks.joined(separator: "\n\n").prefix(6500))
                await diagnostic("Current search evidence lanes=\(blocks.count) chars=\(combined.count) query=\(trimmed)")
                return combined
            }

            // Instant Answer is a last retrieval fallback only; it is never mixed with model memory.
            if let instant = await instantAnswer(trimmed), !instant.isEmpty {
                await diagnostic("DuckDuckGo Instant Answer fallback SUCCESS chars=\(instant.count) query=\(trimmed)")
                return instant
            }
            return ""
        }

        // Stable/general queries keep the low-latency existing path.
        if let tavily = await tavilySearch(trimmed), !tavily.isEmpty {
            await diagnostic("Tavily SUCCESS chars=\(tavily.count) query=\(trimmed)")
            return tavily
        }
        if tavilyConfigured {
            await diagnostic("Tavily unavailable -> falling back to DuckDuckGo query=\(trimmed)")
        }
        if let instant = await instantAnswer(trimmed), !instant.isEmpty {
            await diagnostic("DuckDuckGo Instant Answer SUCCESS chars=\(instant.count) query=\(trimmed)")
            return instant
        }
        let html = await htmlResults(trimmed)
        if !html.isEmpty {
            await diagnostic("DuckDuckGo HTML SUCCESS chars=\(html.count) query=\(trimmed)")
        }
        return html
    }

    // MARK: - Tavily

    static func testTavily(apiKey: String) async -> TavilyTestResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return TavilyTestResult(success: false, message: "Informe uma chave Tavily primeiro.")
        }
        guard let url = URL(string: "https://api.tavily.com/search") else {
            return TavilyTestResult(success: false, message: "Endpoint Tavily inválido.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "api_key": key,
            "query": "Tavily connectivity test",
            "search_depth": "basic",
            "max_results": 1,
            "include_answer": false
        ])

        await diagnostic("Tavily TEST started")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await diagnostic("Tavily TEST failed: non-HTTP response")
                return TavilyTestResult(success: false, message: "Resposta inválida do Tavily.")
            }

            switch http.statusCode {
            case 200:
                await diagnostic("Tavily TEST SUCCESS HTTP=200")
                return TavilyTestResult(success: true, message: "Tavily funcionando — API respondeu HTTP 200.")
            case 401, 403:
                await diagnostic("Tavily TEST FAILED HTTP=\(http.statusCode) invalid key/auth")
                return TavilyTestResult(success: false, message: "Chave Tavily inválida ou sem autorização.")
            case 429:
                await diagnostic("Tavily TEST FAILED HTTP=429 rate limit")
                return TavilyTestResult(success: false, message: "Tavily respondeu, mas o limite da conta foi atingido.")
            default:
                await diagnostic("Tavily TEST FAILED HTTP=\(http.statusCode)")
                return TavilyTestResult(success: false, message: "Tavily retornou HTTP \(http.statusCode).")
            }
        } catch {
            await diagnostic("Tavily TEST FAILED error=\(error.localizedDescription)")
            return TavilyTestResult(success: false, message: "Falha de conexão: \(error.localizedDescription)")
        }
    }

    private static func tavilySearch(
        _ query: String,
        searchDepth: String = "basic",
        maxResults: Int = 5,
        includeAnswer: Bool = true
    ) async -> String? {
        let key = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !key.isEmpty, let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = searchDepth == "advanced" ? 15 : 12
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "search_depth": searchDepth,
            "max_results": maxResults,
            "include_answer": includeAnswer
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        await diagnostic("Tavily request started depth=\(searchDepth) answer=\(includeAnswer) query=\(query)")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await diagnostic("Tavily FAILED non-HTTP response")
                return nil
            }
            guard http.statusCode == 200 else {
                await diagnostic("Tavily FAILED HTTP=\(http.statusCode)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await diagnostic("Tavily FAILED invalid JSON")
                return nil
            }

            var parts: [String] = []
            if includeAnswer, let answer = json["answer"] as? String, !answer.isEmpty {
                parts.append("Resposta sintetizada Tavily: \(String(answer.prefix(700)))")
            }

            if let results = json["results"] as? [[String: Any]] {
                for (index, result) in results.prefix(maxResults).enumerated() {
                    guard let content = (result["content"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
                    let title = (result["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Resultado"
                    let sourceURL = (result["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let published = (result["published_date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = String(content.prefix(includeAnswer ? 350 : 650))
                    var line = "\(index + 1). \(title): \(snippet)"
                    if let published, !published.isEmpty { line += "\nPublicado/atualizado: \(published)" }
                    if !sourceURL.isEmpty { line += "\nFonte: \(sourceURL)" }
                    parts.append(line)
                }
            }

            let limit = includeAnswer ? 3200 : 5200
            let combined = String(parts.joined(separator: "\n").prefix(limit))
            guard !combined.isEmpty else {
                await diagnostic("Tavily FAILED HTTP=200 but no usable content")
                return nil
            }
            return combined
        } catch {
            await diagnostic("Tavily FAILED error=\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - DuckDuckGo Instant Answer

    private static func instantAnswer(_ query: String) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
            return nil
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let answer = json["Answer"] as? String, !answer.isEmpty { return answer }
            if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                let source = json["AbstractSource"] as? String ?? ""
                let sourceURL = json["AbstractURL"] as? String ?? ""
                var value = source.isEmpty ? abstract : "\(abstract) (via \(source))"
                if !sourceURL.isEmpty { value += "\nFonte: \(sourceURL)" }
                return value
            }
            if let topics = json["RelatedTopics"] as? [[String: Any]] {
                let summaries = topics.prefix(3).compactMap { topic -> String? in
                    guard let text = topic["Text"] as? String, !text.isEmpty else { return nil }
                    if let url = topic["FirstURL"] as? String, !url.isEmpty {
                        return "\(text)\nFonte: \(url)"
                    }
                    return text
                }
                if !summaries.isEmpty { return summaries.joined(separator: "\n") }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - DuckDuckGo HTML search

    private struct HTMLResult {
        let title: String
        let snippet: String
        let url: String?
    }

    private static func htmlResults(_ query: String) async -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ""
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return ""
            }

            let results = parseResults(from: html, limit: 5)
            if results.isEmpty { return "" }

            return results.enumerated().map { index, result in
                var line = "\(index + 1). \(result.title): \(result.snippet)"
                if let sourceURL = result.url, !sourceURL.isEmpty {
                    line += "\nFonte: \(sourceURL)"
                }
                return line
            }.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    private static func parseResults(from html: String, limit: Int) -> [HTMLResult] {
        let titlePattern = #"<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class=\"result__snippet\"[^>]*>(.*?)</a>"#
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])

        let titleMatches = titleRegex?.matches(in: html, range: fullRange) ?? []
        let snippetMatches = snippetRegex?.matches(in: html, range: fullRange) ?? []
        var output: [HTMLResult] = []

        let count = min(limit, max(titleMatches.count, snippetMatches.count))
        for index in 0..<count {
            var title = "Resultado"
            var sourceURL: String?
            var snippet = ""

            if index < titleMatches.count {
                let match = titleMatches[index]
                if match.numberOfRanges > 2,
                   let hrefRange = Range(match.range(at: 1), in: html),
                   let titleRange = Range(match.range(at: 2), in: html) {
                    let rawHref = decodeEntities(String(html[hrefRange]))
                    sourceURL = decodeDuckDuckGoURL(rawHref)
                    title = stripHTML(String(html[titleRange]))
                }
            }

            if index < snippetMatches.count {
                let match = snippetMatches[index]
                if match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: html) {
                    snippet = stripHTML(String(html[range]))
                }
            }

            if snippet.count > 20 || title != "Resultado" {
                output.append(HTMLResult(title: title, snippet: snippet, url: sourceURL))
            }
        }

        return output
    }

    private static func decodeDuckDuckGoURL(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("//") { value = "https:" + value }

        guard let components = URLComponents(string: value) else { return raw }
        if let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           !redirected.isEmpty {
            return redirected
        }
        return value
    }

    private static func stripHTML(_ string: String) -> String {
        let noTags = string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ string: String) -> String {
        var output = string
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#x27;": "'", "&#39;": "'", "&#x2F;": "/", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    private static func isTimeSensitiveQuery(_ query: String) -> Bool {
        let normalized = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        return [
            "hoje", "ontem", "amanha", "agora", "atual", "recent", "ultimo", "proximo",
            "placar", "resultado", "jogo", "partida", "noticia", "noticias", "preco", "cotacao",
            "weather", "tempo", "today", "yesterday", "tomorrow", "latest", "next", "score"
        ].contains { normalized.contains($0) }
    }

    private static func diagnostic(_ message: String) async {
        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", message)
        }
    }
}
