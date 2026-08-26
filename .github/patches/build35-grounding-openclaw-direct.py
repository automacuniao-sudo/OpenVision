from pathlib import Path
import re

ROOT = Path('.')


def read(path):
    return (ROOT / path).read_text()


def write(path, text):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f'missing anchor: {label}')
    return text.replace(old, new, 1)

# -----------------------------------------------------------------------------
# 1) Deterministic iPhone clock tool
# -----------------------------------------------------------------------------
write('JARVIS/Services/NativeTools/CurrentDateTimeTool.swift', r'''// JARVIS - CurrentDateTimeTool.swift
// Deterministic local civil date/time from the iPhone. Never trust model clock memory for "today".

import Foundation

struct CurrentDateTimeTool: NativeTool {
    let name = "current_datetime"
    let description = "AUTHORITATIVE iPhone clock. MUST call this tool before answering any question about the current date, current time, weekday, hoje, agora, ontem, amanhã, yesterday, today, or tomorrow. Its output overrides model memory and UTC assumptions. No network is used."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "additionalProperties": false
    ]

    func execute(args: [String: Any]) async throws -> String {
        let now = Date()
        let timeZone = TimeZone.autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone

        let startToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startToday) ?? startToday
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) ?? startToday

        func formatter(_ format: String, locale: String = "pt_BR") -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: locale)
            f.calendar = calendar
            f.timeZone = timeZone
            f.dateFormat = format
            return f
        }

        let day = formatter("dd/MM/yyyy")
        let weekday = formatter("EEEE")
        let clock = formatter("HH:mm:ss")
        let isoLocal = formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", locale: "en_US_POSIX")
        let offsetSeconds = timeZone.secondsFromGMT(for: now)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absolute = abs(offsetSeconds)
        let offset = String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)

        return """
        RELÓGIO LOCAL AUTORITATIVO DO IPHONE — use estes valores literalmente:
        agora_local = \(isoLocal.string(from: now))
        hoje = \(day.string(from: now))
        dia_da_semana = \(weekday.string(from: now))
        hora_local = \(clock.string(from: now))
        ontem = \(day.string(from: yesterday))
        amanhã = \(day.string(from: tomorrow))
        fuso = \(timeZone.identifier)
        offset_utc = \(offset)
        REGRA: para "hoje" e "agora", nunca substitua estes valores por UTC, memória do modelo ou data do servidor.
        """
    }
}
''')

# -----------------------------------------------------------------------------
# 2) Search provenance store + tool (prevents invented sources/links)
# -----------------------------------------------------------------------------
write('JARVIS/Services/NativeTools/WebSearchEvidenceStore.swift', r'''// JARVIS - WebSearchEvidenceStore.swift
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
''')

# -----------------------------------------------------------------------------
# 3) Register deterministic tools
# -----------------------------------------------------------------------------
p = 'JARVIS/Services/NativeTools/NativeTool.swift'
s = read(p)
s = replace_once(s,
'''            DeviceStatusTool(),
            WebSearchTool(),''',
'''            DeviceStatusTool(),
            CurrentDateTimeTool(),
            WebSearchTool(),
            LastSearchSourcesTool(),''',
'NativeTool registry')
write(p, s)

# -----------------------------------------------------------------------------
# 4) Gemini: tool-ground current date/time + source provenance, preserve realtime runtime untouched
# -----------------------------------------------------------------------------
p = 'JARVIS/Services/GeminiLive/GeminiLiveService.swift'
s = read(p)
s = replace_once(s, 'let localTimeZone = TimeZone.current', 'let localTimeZone = TimeZone.autoupdatingCurrent', 'Gemini timezone')
old = '''        DATE/TIME GROUND TRUTH FROM THE IPHONE: right now locally it is \\(localNow), time zone \\(localTimeZone.identifier). The local civil date called "hoje" is exactly \\(localToday). Treat this iPhone-local date as authoritative. DO NOT convert it to UTC and accidentally call the next UTC date "today". For questions such as "que dia é hoje?", "hoje é dia quanto?" or "que horas são?", answer from this local clock. If the user explicitly asks to search the web, you may call web_search, but reconcile any result to this same iPhone-local calendar date.
'''
new = '''        DATE/TIME SNAPSHOT FROM THE IPHONE AT SESSION START: locally it is \\(localNow), time zone \\(localTimeZone.identifier), and the local civil date is \\(localToday). DO NOT convert this to UTC for the meaning of "hoje".

        MANDATORY CURRENT CLOCK RULE: for ANY question whose answer depends on the current local date/time/weekday or relative civil date — including "que dia é hoje?", "hoje é dia quanto?", "que horas são?", "agora", "ontem" or "amanhã" — CALL `current_datetime` before answering. The live tool result is the authoritative iPhone clock and OVERRIDES your internal date, server date, training knowledge, and UTC date. Never answer these questions from model memory alone.
'''
s = replace_once(s, old, new, 'Gemini date prompt')
old = '''        INTERNET / CURRENT INFORMATION: the native tool `web_search` is available. CALL `web_search` whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current or time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not answer current facts from stale model memory when `web_search` can verify them. For example, "qual é o próximo jogo do Corinthians?" must call `web_search` before answering.
'''
new = '''        INTERNET / CURRENT INFORMATION: CALL `web_search` whenever the user asks to search/pesquisar na internet, or whenever the answer depends on current/time-sensitive information such as sports schedules/results, news, weather, prices, releases, current office-holders, or recent events. Do not answer those facts from stale model memory. For exact sports facts (último/próximo jogo, placar, data, adversário, gols), use ONLY evidence returned by `web_search`; never fill missing fields from memory. If the returned sources conflict or do not clearly establish the requested fact, say that you could not confirm it reliably instead of guessing.

        SOURCE PROVENANCE RULE: when the user asks where a searched fact came from, asks for the specific source/link, asks to verify the link, or asks you to copy the source, you MUST call `last_search_sources`. Never invent a publication name, domain, or URL. If copying a source URL, copy only an exact URL returned by `last_search_sources`, then report success only if `copy_to_clipboard` succeeds.
'''
s = replace_once(s, old, new, 'Gemini search prompt')
s = replace_once(s,
'''        - device_status: read the real iPhone battery percentage, charging state, Low Power Mode, and iOS version. Use it for questions like "quanto de bateria eu tenho?".
''',
'''        - current_datetime: read the authoritative current iPhone local date/time/weekday and today/yesterday/tomorrow. Mandatory for current clock/date questions.
        - device_status: read the real iPhone battery percentage, charging state, Low Power Mode, and iOS version. Use it for questions like "quanto de bateria eu tenho?".
''',
'Gemini current_datetime tool list')
s = replace_once(s,
'''        - web_search: search the current internet for time-sensitive/current information.
''',
'''        - web_search: search the current internet for time-sensitive/current information.
        - last_search_sources: return real provenance/URLs from the most recent web_search; mandatory for source/link follow-ups.
''',
'Gemini provenance tool list')
write(p, s)

# -----------------------------------------------------------------------------
# 5) Web search: current facts use independent raw evidence in parallel; no Tavily synthesized answer
# -----------------------------------------------------------------------------
p = 'JARVIS/Services/Web/WebSearchService.swift'
s = read(p)
start = s.index('    static func search(_ query: String) async -> String {')
end = s.index('    // MARK: - Tavily', start)
new_search = r'''    static func search(_ query: String) async -> String {
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

'''
s = s[:start] + new_search + s[end:]

# Replace Tavily helper with configurable raw/current mode.
pattern = re.compile(r'''    private static func tavilySearch\(_ query: String\) async -> String\? \{.*?\n    \}\n\n    // MARK: - DuckDuckGo Instant Answer''', re.S)
replacement = r'''    private static func tavilySearch(
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

    // MARK: - DuckDuckGo Instant Answer'''
s, count = pattern.subn(replacement, s, count=1)
if count != 1:
    raise SystemExit('missing anchor: tavilySearch helper')
write(p, s)

# -----------------------------------------------------------------------------
# 6) WebSearchTool stores real provenance and labels the dual current search path
# -----------------------------------------------------------------------------
p = 'JARVIS/Services/NativeTools/WebSearchTool.swift'
s = read(p)
s = replace_once(s,
'''            return Self.wrapResult(
                structuredSports,
                query: searchQuery,
                provider: "ESPN estruturado",
                context: dateContext
            )''',
'''            await MainActor.run {
                WebSearchEvidenceStore.shared.record(
                    query: searchQuery,
                    provider: "ESPN estruturado",
                    result: structuredSports
                )
            }
            return Self.wrapResult(
                structuredSports,
                query: searchQuery,
                provider: "ESPN estruturado",
                context: dateContext
            )''',
'WebSearch structured provenance')
old = '''        let provider = await MainActor.run {
            SettingsManager.shared.settings.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "DuckDuckGo"
                : "Tavily→DuckDuckGo"
        }
'''
new = '''        let provider = await MainActor.run {
            let hasTavily = !SettingsManager.shared.settings.tavilyAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if Self.isTimeSensitiveSearch(searchQuery), hasTavily {
                return "Tavily + DuckDuckGo (evidência paralela)"
            }
            return hasTavily ? "Tavily→DuckDuckGo" : "DuckDuckGo"
        }
'''
s = replace_once(s, old, new, 'WebSearch provider label')
s = replace_once(s,
'''        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Search completed provider=\\(provider) chars=\\(result.count)")
        }

        return Self.wrapResult(result, query: searchQuery, provider: provider, context: dateContext)
''',
'''        await MainActor.run {
            DiagnosticLogger.shared.log("WebSearch", "Search completed provider=\\(provider) chars=\\(result.count)")
            WebSearchEvidenceStore.shared.record(query: searchQuery, provider: provider, result: result)
        }

        return Self.wrapResult(result, query: searchQuery, provider: provider, context: dateContext)
''',
'WebSearch generic provenance')
# Add helper before deterministic local date grounding.
s = replace_once(s,
'''    // MARK: - Deterministic local date grounding
''',
'''    private static func isTimeSensitiveSearch(_ query: String) -> Bool {
        let n = normalizeForIntent(query)
        return [
            "hoje", "ontem", "amanha", "agora", "atual", "recente", "ultimo", "proximo",
            "placar", "resultado", "jogo", "partida", "noticia", "preco", "cotacao",
            "today", "yesterday", "tomorrow", "latest", "next", "score", "current", "recent"
        ].contains { n.contains($0) }
    }

    // MARK: - Deterministic local date grounding
''',
'WebSearch time sensitive helper')
write(p, s)

# -----------------------------------------------------------------------------
# 7) OpenClaw: direct tools.invoke for deterministic PC browser actions (bypasses provider quota)
# -----------------------------------------------------------------------------
p = 'JARVIS/Services/OpenClaw/OpenClawProtocol.swift'
s = read(p)
s = replace_once(s,
'''    case toolResult = "tool.result"
''',
'''    case toolResult = "tool.result"
    case toolsInvoke = "tools.invoke"
''',
'OpenClaw tools.invoke enum')
write(p, s)

p = 'JARVIS/Services/OpenClaw/OpenClawService.swift'
s = read(p)
anchor = '''    func cancelRequest() {
'''
method = r'''    /// Invoke OpenClaw's Gateway tool directly, bypassing the agent/model turn. This is used
    /// only for deterministic explicit PC actions, so provider quota (429) cannot block them.
    /// Gateway policy remains authoritative: unavailable/denied tools return an error and caller
    /// falls back to the normal agent path.
    func openWebsiteDirectly(urlString: String) async throws {
        guard connectionState.isUsable else { throw AIBackendError.notConnected }
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AIBackendError.requestFailed("Invalid website URL")
        }

        let params: [String: Any] = [
            "name": "browser",
            "args": [
                "action": "open",
                "url": url.absoluteString,
                "profile": "openclaw",
                "target": "host",
            ],
            "sessionKey": Self.sessionKey,
            "idempotencyKey": UUID().uuidString,
        ]
        DiagnosticLogger.shared.log("OpenClaw", "Direct tools.invoke browser open host requested")
        let response = try await sendRequest(method: .toolsInvoke, params: params)
        guard response.ok else {
            let message = response.error?.message ?? response.error?.code ?? "browser tool unavailable"
            DiagnosticLogger.shared.log("OpenClaw", "Direct tools.invoke rejected: \(message)")
            throw AIBackendError.requestFailed(message)
        }
        DiagnosticLogger.shared.log("OpenClaw", "Direct tools.invoke browser open SUCCESS")
    }

'''
s = replace_once(s, anchor, method + anchor, 'OpenClaw direct browser method')
write(p, s)

# -----------------------------------------------------------------------------
# 8) Route explicit "open YouTube on my computer" directly before model chat
# -----------------------------------------------------------------------------
p = 'JARVIS/Views/VoiceAgent/VoiceAgentViewModel.swift'
s = read(p)
anchor = '''        agentState = .thinking

        // Check if this is a vision-related command
'''
insert = r'''        agentState = .thinking

        // Deterministic PC browser actions do not need an LLM. OpenClaw Gateway exposes
        // tools.invoke, so explicit commands such as "no meu computador abra o YouTube" can still
        // work when the provider configured on the PC is quota-limited. If browser policy/plugin is
        // unavailable, fall through to the normal OpenClaw agent exactly as before.
        if settingsManager.settings.aiBackend == .openClaw,
           let website = directOpenClawWebsiteRequest(command) {
            do {
                try await OpenClawService.shared.openWebsiteDirectly(urlString: website.url)
                let confirmation = "Abri \(website.label) no seu computador."
                aiTranscript = confirmation
                speakResponse(confirmation)
                return
            } catch {
                DiagnosticLogger.shared.log(
                    "OpenClaw",
                    "Direct PC action unavailable; falling back to agent: \(error.localizedDescription)"
                )
            }
        }

        // Check if this is a vision-related command
'''
s = replace_once(s, anchor, insert, 'ViewModel direct OpenClaw route')
helper_anchor = '''    // MARK: - Live Video Mode
'''
helper = r'''    /// Narrow deterministic parser for direct PC website actions. Keep this intentionally
    /// conservative: everything else remains an agent request. More sites/actions can be added once
    /// their OpenClaw tool schemas are validated on the user's runtime.
    private func directOpenClawWebsiteRequest(_ command: String) -> (url: String, label: String)? {
        let n = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let asksOpen = ["abra", "abrir", "abre", "open"].contains { n.contains($0) }
        let targetsPC = ["computador", "meu pc", "no pc", "computer"].contains { n.contains($0) }
        guard asksOpen, targetsPC else { return nil }

        if n.contains("youtube") {
            return ("https://www.youtube.com", "o YouTube")
        }
        return nil
    }

'''
s = replace_once(s, helper_anchor, helper + helper_anchor, 'ViewModel direct action helper')
write(p, s)

# -----------------------------------------------------------------------------
# 9) Build number + notes
# -----------------------------------------------------------------------------
p = 'project.yml'
s = read(p)
s = replace_once(s, 'CURRENT_PROJECT_VERSION: "34"', 'CURRENT_PROJECT_VERSION: "35"', 'build number')
write(p, s)

p = 'JARVIS_BUILD_NOTES.md'
s = read(p)
notes = '''\n## Build 35 — deterministic grounding + direct OpenClaw PC actions\n- Conversation runtime intentionally unchanged from Build 34.\n- Added `current_datetime`: authoritative iPhone-local clock for today/time/weekday/relative dates.\n- Gemini must use `current_datetime` instead of internal/server/UTC date memory.\n- Current/time-sensitive web searches now run raw Tavily Advanced + DuckDuckGo evidence in parallel; Tavily synthesized answer is disabled for current facts.\n- Added `last_search_sources` + provenance store so source/link follow-ups cannot legitimately invent Gazeta/URLs.\n- Exact sports facts are instructed to answer only from returned evidence and admit insufficient/conflicting evidence instead of guessing.\n- Added OpenClaw Gateway `tools.invoke` support for deterministic PC actions. `open YouTube on my computer` invokes the browser tool directly on host, bypassing provider model quota; denied/unavailable browser falls back to agent.\n'''
write(p, notes + s)

print('Build 35 patch applied successfully')
