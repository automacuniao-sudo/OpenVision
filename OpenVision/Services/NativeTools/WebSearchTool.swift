// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// IMPORTANT: this tool intentionally delegates to WebSearchService so Settings > Web Search is
// the source of truth. Tavily is used when the user configured a key; otherwise the existing
// keyless DuckDuckGo pipeline is used. Gemini Live only receives the returned findings.

import Foundation

struct WebSearchTool: NativeTool {
    let name = "web_search"
    let description = "Search the current internet for genuinely time-sensitive information using the provider configured in Settings > Web Search. Use for explicit pesquisar/buscar requests and facts that can change, such as sports scores/schedules, news, weather, prices, releases, current office-holders, or recent events. Do NOT use this tool for stable general-knowledge facts such as country capitals unless the user explicitly asks to search. For sports questions like último jogo/próximo jogo, only answer when the findings clearly support the date, opponent, and score/schedule; if results are ambiguous or conflicting, search again with the absolute date instead of guessing. Relative dates are resolved from the iPhone's local calendar before searching."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "A concise web-search query. For time-sensitive questions include the team/person/topic; JARVIS will resolve hoje/ontem/amanhã and last/next relative to the iPhone's current local date."
            ]
        ],
        "required": ["query"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let rawQuery = args["query"] as? String else { throw WebSearchError.invalidQuery }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw WebSearchError.invalidQuery }

        let dateContext = Self.localDateContext()
        let searchQuery = Self.resolveTemporalTerms(in: query, context: dateContext)

        let provider = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "DuckDuckGo"
                : "Tavily→DuckDuckGo"
        }
        await MainActor.run {
            DiagnosticLogger.shared.log(
                "WebSearch",
                "Searching provider=\(provider) query=\(searchQuery)"
            )
        }

        let result = await WebSearchService.search(searchQuery)
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

        // Give Gemini an explicit, deterministic calendar reference with every web result. This is
        // intentionally generated on-device instead of asking the model to infer "ontem" from an
        // ISO timestamp. It prevents date-rollover mistakes near midnight and makes sports checks
        // auditable in Diagnostics.
        return """
        CONTEXTO TEMPORAL DO IPHONE — fonte de verdade para datas relativas:
        hoje = \(dateContext.todayDisplay) (\(dateContext.todayISO))
        ontem = \(dateContext.yesterdayDisplay) (\(dateContext.yesterdayISO))
        amanhã = \(dateContext.tomorrowDisplay) (\(dateContext.tomorrowISO))
        fuso = \(dateContext.timeZoneIdentifier)
        consulta executada = \(searchQuery)
        provedor = \(provider)

        RESULTADOS DA WEB:
        \(result)

        Ao responder, não reinterprete hoje/ontem/amanhã. Para placar ou agenda esportiva, só afirme um resultado quando os achados acima deixarem clara a data e a partida; se estiver ambíguo, faça outra busca mais específica em vez de completar pela memória.
        """
    }

    // MARK: - Deterministic local date grounding

    private struct LocalDateContext {
        let todayISO: String
        let yesterdayISO: String
        let tomorrowISO: String
        let todayDisplay: String
        let yesterdayDisplay: String
        let tomorrowDisplay: String
        let timeZoneIdentifier: String
    }

    private static func localDateContext(now: Date = Date()) -> LocalDateContext {
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.calendar = calendar
        iso.timeZone = timeZone
        iso.dateFormat = "yyyy-MM-dd"

        let display = DateFormatter()
        display.locale = Locale(identifier: "pt_BR")
        display.calendar = calendar
        display.timeZone = timeZone
        display.dateFormat = "dd/MM/yyyy"

        return LocalDateContext(
            todayISO: iso.string(from: today),
            yesterdayISO: iso.string(from: yesterday),
            tomorrowISO: iso.string(from: tomorrow),
            todayDisplay: display.string(from: today),
            yesterdayDisplay: display.string(from: yesterday),
            tomorrowDisplay: display.string(from: tomorrow),
            timeZoneIdentifier: timeZone.identifier
        )
    }

    private static func resolveTemporalTerms(in query: String, context: LocalDateContext) -> String {
        var resolved = query

        // Replace explicit relative-day words with both the natural word and the exact calendar
        // date so search providers cannot silently assume a server-side date or time zone.
        resolved = resolved.replacingOccurrences(
            of: "ontem",
            with: "ontem \(context.yesterdayDisplay)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "hoje",
            with: "hoje \(context.todayDisplay)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "amanhã",
            with: "amanhã \(context.tomorrowDisplay)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "amanha",
            with: "amanha \(context.tomorrowDisplay)",
            options: [.caseInsensitive]
        )

        let normalized = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        let asksLast = [
            "ultimo jogo", "ultima partida", "jogo mais recente", "partida mais recente",
            "last game", "last match", "latest game", "latest match"
        ].contains { normalized.contains($0) }

        let asksNext = [
            "proximo jogo", "proxima partida", "next game", "next match"
        ].contains { normalized.contains($0) }

        if asksLast {
            resolved += " — referência local: antes de \(context.todayDisplay); identificar a partida concluída mais recente com data, adversário e placar"
        } else if asksNext {
            resolved += " — referência local: a partir de \(context.todayDisplay); identificar a próxima partida futura com data e adversário"
        }

        return resolved
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
