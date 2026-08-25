// OpenVision - WebSearchService.swift
// Free/current web search for JARVIS.
//
// Priority: Tavily when configured; otherwise DuckDuckGo HTML for time-sensitive queries and
// DuckDuckGo Instant Answer for stable factual lookups. HTML results now preserve title + source URL
// so Gemini can distinguish sources instead of reasoning from anonymous snippets alone.

import Foundation

enum WebSearchService {

    static func search(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 1) Tavily (if configured): best generic provider for fresh/current information.
        if let tavily = await tavilySearch(trimmed), !tavily.isEmpty {
            return tavily
        }

        let timeSensitive = isTimeSensitiveQuery(trimmed)

        // 2) For current information, prefer real result pages. Instant Answer can surface an old
        // fact that happens to match the entity name, which is especially dangerous for schedules.
        if timeSensitive {
            let html = await htmlResults(trimmed)
            if !html.isEmpty { return html }
            return await instantAnswer(trimmed) ?? ""
        }

        // 3) Stable fact/definition path.
        if let instant = await instantAnswer(trimmed), !instant.isEmpty {
            return instant
        }

        // 4) Generic no-key fallback.
        return await htmlResults(trimmed)
    }

    // MARK: - Tavily

    private static func tavilySearch(_ query: String) async -> String? {
        let key = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !key.isEmpty, let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            "include_answer": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[OV] Tavily unavailable (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }

            var parts: [String] = []
            if let answer = json["answer"] as? String, !answer.isEmpty {
                parts.append("Resposta sintetizada Tavily: \(String(answer.prefix(700)))")
            }

            if let results = json["results"] as? [[String: Any]] {
                for (index, result) in results.prefix(4).enumerated() {
                    guard let content = (result["content"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
                    let title = (result["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Resultado"
                    let sourceURL = (result["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let snippet = String(content.prefix(350))
                    var line = "\(index + 1). \(title): \(snippet)"
                    if !sourceURL.isEmpty { line += "\nFonte: \(sourceURL)" }
                    parts.append(line)
                }
            }

            let combined = String(parts.joined(separator: "\n").prefix(3200))
            if !combined.isEmpty {
                NSLog("[OV] Tavily hit: %d chars for \"%@\"", combined.count, query)
            }
            return combined.isEmpty ? nil : combined
        } catch {
            NSLog("[OV] Tavily error: %@", "\(error)")
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
                NSLog("[OV] web search (html): unavailable (HTTP %d)", (response as? HTTPURLResponse)?.statusCode ?? 0)
                return ""
            }

            let results = parseResults(from: html, limit: 5)
            if results.isEmpty {
                NSLog("[OV] web search (html): no results parsed for \"%@\"", query)
                return ""
            }

            return results.enumerated().map { index, result in
                var line = "\(index + 1). \(result.title): \(result.snippet)"
                if let sourceURL = result.url, !sourceURL.isEmpty {
                    line += "\nFonte: \(sourceURL)"
                }
                return line
            }.joined(separator: "\n")
        } catch {
            NSLog("[OV] web search (html) failed: %@", "\(error)")
            return ""
        }
    }

    private static func parseResults(from html: String, limit: Int) -> [HTMLResult] {
        let titlePattern = #"<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class=\"result__snippet\"[^>]*>(.*?)</a>"#
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        let titleRegex = try? NSRegularExpression(
            pattern: titlePattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let snippetRegex = try? NSRegularExpression(
            pattern: snippetPattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )

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
}
