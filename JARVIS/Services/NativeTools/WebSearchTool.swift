// OpenVision - WebSearchTool.swift
// Current-information search bridge for JARVIS.
//
// Sports score/schedule questions first use structured football data when possible. Generic web
// search remains the fallback and Settings > Web Search is still the source of truth for Tavily.

import Foundation

struct WebSearchTool: NativeTool {
    let name = "web_search"
    let description = "Search current information. Use for explicit pesquisar/buscar requests and genuinely time-sensitive facts such as sports results/schedules, news, weather, prices, releases, current office-holders, or recent events. Do NOT use for stable general knowledge, biographies/history, country capitals, or a generic 'fale sobre X' unless the user explicitly asks for current/latest/recent information or asks to search. For football score/schedule/scorer questions, structured sports data is tried before generic snippets. If the user says 'pesquise no Google', do not pretend Google is integrated: use the configured provider and state the real provider if relevant. Relative dates are resolved deterministically from the iPhone clock."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "A concise search query. For current sports include the team and intent (placar, gols, último/próximo jogo). Preserve the user's original intent across follow-ups; never change último into próximo or vice-versa. Do not invent a calendar date for hoje/ontem/amanhã; the iPhone resolves it."
            ]
        ],
        "required": ["query"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let rawQuery = args["query"] as? String else { throw WebSearchError.invalidQuery }
        let modelQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelQuery.isEmpty else { throw WebSearchError.invalidQuery }

        // A bare follow-up such as "pesquise no Google" has no topic of its own. Gemini sometimes
        // rewrites that into a different intent (observed on-device: "último jogo" became
        // "próximo jogo"). Recover the last meaningful user utterance instead of trusting that
        // semantic drift. This is deliberately narrow: searches that contain their own topic keep
        // the model-supplied query.
        let recentCommands = await MainActor.run { NativeToolContext.shared.recentCommands() }
        let query = Self.preserveUserSearchIntent(modelQuery: modelQuery, recentCommands: recentCommands)
        if query != modelQuery {
            await MainActor.run {
                DiagnosticLogger.shared.log(
                    "WebSearch",
                    "Grounded referential search modelQuery=\(modelQuery) userIntent=\(query)"
                )
            }
        }

        let dateContext = Self.localDateContext()
        let searchQuery = Self.resolveTemporalTerms(in: query, context: dateContext)

        // Structured football data is much safer than search snippets for exact scores, opponents,
        // schedules and goal scorers. It is keyless and falls through silently if ESPN does not
        // cover the requested competition/event.
        if let structuredSports = await SportsDataService.lookup(searchQuery) {
            await MainActor.run {
                DiagnosticLogger.shared.log(
                    "WebSearch",
                    "Structured sports hit provider=ESPN query=\(searchQuery)"
                )
            }
            return Self.wrapResult(
                structuredSports,
                query: searchQuery,
                provider: "ESPN estruturado",
                context: dateContext
            )
        }

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

        return Self.wrapResult(result, query: searchQuery, provider: provider, context: dateContext)
    }

    private static func wrapResult(
        _ result: String,
        query: String,
        provider: String,
        context: LocalDateContext
    ) -> String {
        """
        CONTEXTO TEMPORAL DO IPHONE — fonte de verdade para datas relativas:
        hoje = \(context.todayDisplay) (\(context.todayISO))
        ontem = \(context.yesterdayDisplay) (\(context.yesterdayISO))
        amanhã = \(context.tomorrowDisplay) (\(context.tomorrowISO))
        fuso = \(context.timeZoneIdentifier)
        consulta executada = \(query)
        provedor real = \(provider)

        RESULTADOS:
        \(result)

        REGRAS DE RESPOSTA:
        - Não reinterprete hoje/ontem/amanhã e não substitua a data local por uma data da memória do modelo.
        - Nunca diga que pesquisou no Google quando o campo 'provedor real' acima indicar outro serviço.
        - Preserve exatamente a intenção temporal da consulta: último/mais recente nunca pode virar próximo/futuro, e próximo nunca pode virar último.
        - Se a consulta pedir o último jogo/resultado e os resultados sustentarem uma partida concluída mais recente, responda diretamente com data, adversário e placar; não peça campeonato ou uma data específica desnecessariamente.
        - Em placar, agenda ou autores de gols, use somente dados que estejam claramente sustentados pelos resultados. Se adversário/data/placar estiverem ambíguos, faça outra busca mais específica em vez de adivinhar.
        - Não misture snippets antigos com memória do modelo para preencher campos ausentes.
        """
    }

    // MARK: - Follow-up intent grounding

    private static func preserveUserSearchIntent(modelQuery: String, recentCommands: [String]) -> String {
        guard let current = recentCommands.last,
              isBareSearchFollowUp(current) else {
            return modelQuery
        }

        for candidate in recentCommands.dropLast().reversed() {
            if isMeaningfulSearchAnchor(candidate) {
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return modelQuery
    }

    private static func isBareSearchFollowUp(_ text: String) -> Bool {
        let n = normalizeForIntent(text)
        let exact = [
            "pesquise", "pesquisar", "procure", "buscar", "busque",
            "pesquise no google", "pesquisar no google", "procure no google", "busque no google",
            "pesquise na internet", "pesquisar na internet", "procure na internet", "busque na internet",
            "pesquise isso", "pesquise isso no google", "pesquise isso na internet",
            "procure isso", "procure isso no google", "procure isso na internet",
            "pesquise novamente", "procure novamente", "busque novamente",
            "pesquise de novo", "procure de novo", "busque de novo"
        ]
        return exact.contains(n)
    }

    private static func isMeaningfulSearchAnchor(_ text: String) -> Bool {
        let n = normalizeForIntent(text)
        guard !n.isEmpty, !isBareSearchFollowUp(text) else { return false }

        let acknowledgements = [
            "sim", "nao", "isso", "isso pode ser", "pode ser", "ok", "okay", "certo",
            "beleza", "entendi", "continue", "continua", "por favor", "obrigado", "obrigada"
        ]
        if acknowledgements.contains(n) { return false }

        let stopCommands = ["pare", "jarvis pare", "pare jarvis", "stop", "jarvis stop"]
        if stopCommands.contains(n) { return false }

        // At least one topic-like token keeps tiny conversational fillers from becoming the anchor.
        let tokens = n.split(separator: " ").filter { $0.count >= 4 }
        return !tokens.isEmpty
    }

    private static func normalizeForIntent(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let normalized = normalizeForIntent(query)

        let hasYesterday = normalized.contains("ontem") || normalized.contains("yesterday")
        let hasToday = normalized.contains("hoje") || normalized.contains("today")
        let hasTomorrow = normalized.contains("amanha") || normalized.contains("tomorrow")

        // Gemini sometimes supplied a conflicting explicit date together with a relative word,
        // e.g. "ontem 24/08/2026" while the iPhone correctly said yesterday was 23/08. Strip any
        // model-generated dates in that case and insert one authoritative date only.
        var resolved = (hasYesterday || hasToday || hasTomorrow)
            ? removingExplicitDates(from: query)
            : query

        resolved = resolved.replacingOccurrences(
            of: "ontem",
            with: "ontem \(context.yesterdayDisplay)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "yesterday",
            with: "yesterday \(context.yesterdayISO)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "hoje",
            with: "hoje \(context.todayDisplay)",
            options: [.caseInsensitive]
        )
        resolved = resolved.replacingOccurrences(
            of: "today",
            with: "today \(context.todayISO)",
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
        resolved = resolved.replacingOccurrences(
            of: "tomorrow",
            with: "tomorrow \(context.tomorrowISO)",
            options: [.caseInsensitive]
        )

        let asksLast = asksForLastSportsEvent(normalized)
        let asksNext = asksForNextSportsEvent(normalized)

        if asksLast {
            resolved += " — referência local: antes de \(context.todayDisplay); identificar a partida concluída mais recente com data, adversário e placar"
        } else if asksNext {
            resolved += " — referência local: a partir de \(context.todayDisplay); identificar a próxima partida futura com data, adversário e competição"
        }

        return resolved
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func asksForLastSportsEvent(_ normalized: String) -> Bool {
        let sportsNouns = ["jogo", "partida", "resultado", "placar", "match", "game", "score"]
        let lastMarkers = ["ultimo", "ultima", "mais recente", "last", "latest", "recent result"]
        return lastMarkers.contains(where: normalized.contains)
            && sportsNouns.contains(where: normalized.contains)
    }

    private static func asksForNextSportsEvent(_ normalized: String) -> Bool {
        let sportsNouns = ["jogo", "partida", "match", "game"]
        let nextMarkers = ["proximo", "proxima", "next"]
        return nextMarkers.contains(where: normalized.contains)
            && sportsNouns.contains(where: normalized.contains)
    }

    private static func removingExplicitDates(from query: String) -> String {
        var cleaned = query
        let patterns = [
            #"\b\d{1,2}/\d{1,2}/\d{4}\b"#,
            #"\b\d{4}-\d{1,2}-\d{1,2}\b"#
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression]
            )
        }
        return cleaned
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
