// OpenVision - SportsDataService.swift
// Structured football lookup used before generic web snippets for score/schedule questions.

import Foundation

enum SportsDataService {
    private struct LeagueDescriptor: Sendable {
        let slug: String
        let name: String
    }

    private struct TeamInfo {
        let displayName: String
        let aliases: [String]
        let score: String?
        let homeAway: String?
    }

    private struct EventCandidate {
        let id: String
        let league: LeagueDescriptor
        let name: String
        let date: Date
        let completed: Bool
        let statusText: String
        let teams: [TeamInfo]
        let goals: [String]
        let sourceURL: String
    }

    /// Competitions most likely to contain a Brazilian club's next/last senior men's match.
    /// ESPN's site API is public and keyless but not an officially supported developer API, so
    /// every lookup has a generic-web fallback in WebSearchTool.
    private static let leagues: [LeagueDescriptor] = [
        .init(slug: "bra.1", name: "Campeonato Brasileiro Série A"),
        .init(slug: "bra.copa_do_brazil", name: "Copa do Brasil"),
        .init(slug: "conmebol.libertadores", name: "CONMEBOL Libertadores"),
        .init(slug: "conmebol.sudamericana", name: "CONMEBOL Sudamericana")
    ]

    static func lookup(_ query: String, referenceDate: Date = Date()) async -> String? {
        let normalized = normalize(query)
        guard isFootballEventQuery(normalized) else { return nil }

        var calendar = Calendar.autoupdatingCurrent
        let timeZone = TimeZone.autoupdatingCurrent
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: referenceDate)

        let asksYesterday = normalized.contains("ontem") || normalized.contains("yesterday")
        let asksNext = containsAny(normalized, [
            "proximo jogo", "proxima partida", "next game", "next match"
        ])
        let asksLast = containsAny(normalized, [
            "ultimo jogo", "ultima partida", "jogo mais recente", "partida mais recente",
            "last game", "last match", "latest game", "latest match"
        ])
        let asksGoals = containsAny(normalized, [
            "gol", "gols", "quem marcou", "marcadores", "scorer", "scorers", "goals"
        ])

        let explicitDates = parseDates(in: query, calendar: calendar, timeZone: timeZone)

        let startDate: Date
        let endDate: Date
        if asksYesterday {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            let exact = explicitDates.first ?? yesterday
            startDate = calendar.startOfDay(for: exact)
            endDate = startDate
        } else if asksNext {
            startDate = today
            endDate = calendar.date(byAdding: .day, value: 35, to: today) ?? today
        } else if asksLast {
            startDate = calendar.date(byAdding: .day, value: -21, to: today) ?? today
            endDate = today
        } else if let first = explicitDates.min(), let last = explicitDates.max() {
            startDate = calendar.startOfDay(for: first)
            endDate = calendar.startOfDay(for: last)
        } else {
            startDate = calendar.date(byAdding: .day, value: -2, to: today) ?? today
            endDate = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        }

        let events = await fetchEvents(startDate: startDate, endDate: endDate, timeZone: timeZone)
        guard !events.isEmpty else { return nil }

        var relevant = events
            .map { ($0, relevance(of: $0, to: normalized)) }
            .filter { $0.1 > 0 }

        guard !relevant.isEmpty else { return nil }

        if asksNext {
            relevant = relevant.filter { !$0.0.completed && $0.0.date >= referenceDate.addingTimeInterval(-300) }
            relevant.sort {
                if $0.0.date != $1.0.date { return $0.0.date < $1.0.date }
                return $0.1 > $1.1
            }
        } else if asksLast {
            relevant = relevant.filter { $0.0.completed && $0.0.date <= referenceDate }
            relevant.sort {
                if $0.0.date != $1.0.date { return $0.0.date > $1.0.date }
                return $0.1 > $1.1
            }
        } else {
            relevant.sort {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return abs($0.0.date.timeIntervalSince(referenceDate)) < abs($1.0.date.timeIntervalSince(referenceDate))
            }
        }

        guard var selected = relevant.first?.0 else { return nil }

        // Scoreboard payloads normally include goal details, but some competitions omit them.
        // For a scorer question, ask the event summary before falling back to generic web search.
        if asksGoals && selected.goals.isEmpty,
           let summaryGoals = await fetchSummaryGoals(eventID: selected.id, league: selected.league),
           !summaryGoals.isEmpty {
            selected = EventCandidate(
                id: selected.id,
                league: selected.league,
                name: selected.name,
                date: selected.date,
                completed: selected.completed,
                statusText: selected.statusText,
                teams: selected.teams,
                goals: summaryGoals,
                sourceURL: selected.sourceURL
            )
        }

        // If the user explicitly asked who scored and the structured provider still has no goal
        // details, let the generic provider try instead of encouraging the model to guess.
        if asksGoals && selected.goals.isEmpty { return nil }

        return render(selected, timeZone: timeZone)
    }

    // MARK: - ESPN

    private static func fetchEvents(startDate: Date, endDate: Date, timeZone: TimeZone) async -> [EventCandidate] {
        await withTaskGroup(of: [EventCandidate].self) { group in
            for league in leagues {
                group.addTask {
                    await fetchLeagueEvents(league, startDate: startDate, endDate: endDate, timeZone: timeZone)
                }
            }

            var all: [EventCandidate] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all
        }
    }

    private static func fetchLeagueEvents(
        _ league: LeagueDescriptor,
        startDate: Date,
        endDate: Date,
        timeZone: TimeZone
    ) async -> [EventCandidate] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyyMMdd"
        let start = dayFormatter.string(from: startDate)
        let end = dayFormatter.string(from: endDate)
        let range = start == end ? start : "\(start)-\(end)"

        guard var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league.slug)/scoreboard"
        ) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "dates", value: range),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "lang", value: "pt"),
            URLQueryItem(name: "region", value: "br")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("OpenVision-JARVIS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["events"] as? [[String: Any]] else {
                return []
            }

            return events.compactMap { parseEvent($0, league: league, sourceURL: url.absoluteString) }
        } catch {
            return []
        }
    }

    private static func parseEvent(
        _ event: [String: Any],
        league: LeagueDescriptor,
        sourceURL: String
    ) -> EventCandidate? {
        guard let id = event["id"] as? String,
              let dateString = event["date"] as? String,
              let date = parseISODate(dateString),
              let competitions = event["competitions"] as? [[String: Any]],
              let competition = competitions.first,
              let rawCompetitors = competition["competitors"] as? [[String: Any]] else {
            return nil
        }

        let teams: [TeamInfo] = rawCompetitors.compactMap { competitor in
            guard let team = competitor["team"] as? [String: Any] else { return nil }
            let displayName = firstString(
                team["displayName"], team["shortDisplayName"], team["name"], team["location"]
            ) ?? "Time"
            let aliases = [
                team["displayName"] as? String,
                team["shortDisplayName"] as? String,
                team["name"] as? String,
                team["location"] as? String,
                team["abbreviation"] as? String
            ].compactMap { $0 }

            let score: String?
            if let value = competitor["score"] as? String {
                score = value
            } else if let value = competitor["score"] as? NSNumber {
                score = value.stringValue
            } else {
                score = nil
            }

            return TeamInfo(
                displayName: displayName,
                aliases: aliases,
                score: score,
                homeAway: competitor["homeAway"] as? String
            )
        }

        guard teams.count >= 2 else { return nil }

        let status = event["status"] as? [String: Any]
        let type = status?["type"] as? [String: Any]
        let completed = type?["completed"] as? Bool ?? false
        let statusText = firstString(type?["description"], type?["shortDetail"], type?["detail"]) ?? (completed ? "encerrada" : "agendada")
        let eventName = firstString(event["name"], event["shortName"]) ?? teams.map(\.displayName).joined(separator: " x ")
        let details = competition["details"] as? [[String: Any]] ?? []
        let goals = goalDescriptions(from: details)

        return EventCandidate(
            id: id,
            league: league,
            name: eventName,
            date: date,
            completed: completed,
            statusText: statusText,
            teams: teams,
            goals: goals,
            sourceURL: sourceURL
        )
    }

    private static func fetchSummaryGoals(eventID: String, league: LeagueDescriptor) async -> [String]? {
        guard var components = URLComponents(
            string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league.slug)/summary"
        ) else { return nil }
        components.queryItems = [URLQueryItem(name: "event", value: eventID)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("OpenVision-JARVIS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            var goals: [String] = []
            if let keyEvents = json["keyEvents"] as? [[String: Any]] {
                goals.append(contentsOf: goalDescriptions(from: keyEvents))
            }
            if goals.isEmpty, let plays = json["plays"] as? [[String: Any]] {
                goals.append(contentsOf: goalDescriptions(from: plays))
            }
            return unique(goals)
        } catch {
            return nil
        }
    }

    // MARK: - Selection / rendering

    private static func relevance(of event: EventCandidate, to normalizedQuery: String) -> Int {
        var score = 0
        for team in event.teams {
            for alias in team.aliases {
                let normalizedAlias = normalize(alias)
                guard normalizedAlias.count >= 3 else { continue }
                if normalizedQuery.contains(normalizedAlias) {
                    score += 100
                    break
                }

                for token in normalizedAlias.split(separator: " ") where token.count >= 4 {
                    if normalizedQuery.contains(String(token)) {
                        score += 12
                    }
                }
            }
        }
        return score
    }

    private static func render(_ event: EventCandidate, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM/yyyy HH:mm"

        let orderedTeams = event.teams.sorted { lhs, rhs in
            if lhs.homeAway == rhs.homeAway { return lhs.displayName < rhs.displayName }
            return lhs.homeAway == "home"
        }

        var lines: [String] = [
            "DADOS ESPORTIVOS ESTRUTURADOS — priorize estes campos sobre snippets genéricos:",
            "competição: \(event.league.name)",
            "data/hora local: \(formatter.string(from: event.date))",
            "partida: \(orderedTeams.map(\.displayName).joined(separator: " x "))",
            "status: \(event.statusText)"
        ]

        if event.completed,
           orderedTeams.count >= 2,
           let firstScore = orderedTeams[0].score,
           let secondScore = orderedTeams[1].score {
            lines.append("placar final: \(orderedTeams[0].displayName) \(firstScore) x \(secondScore) \(orderedTeams[1].displayName)")
        }

        if !event.goals.isEmpty {
            lines.append("gols: \(event.goals.joined(separator: "; "))")
        }

        lines.append("fonte: ESPN Site API pública sem chave (integração não oficial)")
        lines.append("fonte_url: \(event.sourceURL)")
        lines.append("REGRA: não troque adversário, data, placar ou autores dos gols por memória do modelo. Se faltar algum campo pedido, faça outra busca em vez de inventar.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Goal extraction

    private static func goalDescriptions(from items: [[String: Any]]) -> [String] {
        var output: [String] = []

        for item in items {
            let type = item["type"] as? [String: Any]
            let typeText = firstString(type?["text"], type?["description"], type?["name"], item["type"] as? String) ?? ""
            let normalizedType = normalize(typeText)
            let isGoal = (item["scoringPlay"] as? Bool == true)
                || normalizedType.contains("goal")
                || normalizedType.contains("gol")
            guard isGoal else { continue }

            if let text = firstString(item["text"], item["shortText"], item["description"]), !text.isEmpty {
                output.append(stripWhitespace(text))
                continue
            }

            var athleteName: String?
            let athleteCollections = ["athletes", "participants"]
            for key in athleteCollections {
                if let people = item[key] as? [[String: Any]], let first = people.first {
                    if let athlete = first["athlete"] as? [String: Any] {
                        athleteName = firstString(athlete["displayName"], athlete["shortName"], athlete["fullName"])
                    }
                    athleteName = athleteName ?? firstString(first["displayName"], first["shortName"], first["name"])
                }
            }

            let teamName: String? = {
                guard let team = item["team"] as? [String: Any] else { return nil }
                return firstString(team["displayName"], team["shortDisplayName"], team["name"])
            }()
            let clock: String? = {
                guard let clock = item["clock"] as? [String: Any] else { return nil }
                return firstString(clock["displayValue"], clock["value"])
            }()

            var parts: [String] = []
            if let athleteName { parts.append(athleteName) }
            if let teamName { parts.append("(\(teamName))") }
            if let clock { parts.append(clock) }
            if !parts.isEmpty { output.append(parts.joined(separator: " ")) }
        }

        return unique(output)
    }

    // MARK: - Date / text helpers

    private static func parseDates(in text: String, calendar: Calendar, timeZone: TimeZone) -> [Date] {
        var dates: [Date] = []
        let patterns: [(String, String)] = [
            (#"\b\d{2}/\d{2}/\d{4}\b"#, "dd/MM/yyyy"),
            (#"\b\d{4}-\d{2}-\d{2}\b"#, "yyyy-MM-dd")
        ]

        for (pattern, format) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let raw = String(text[swiftRange])
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
                formatter.timeZone = timeZone
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { dates.append(date) }
            }
        }
        return dates
    }

    private static func isFootballEventQuery(_ normalized: String) -> Bool {
        containsAny(normalized, [
            "jogo", "partida", "placar", "resultado", "gol", "gols", "marcou", "marcaram",
            "proximo", "proxima", "ultimo", "ultima", "calendario", "agenda",
            "match", "score", "scorer", "goal", "goals"
        ])
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func firstString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func stripWhitespace(_ string: String) -> String {
        string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }
}
