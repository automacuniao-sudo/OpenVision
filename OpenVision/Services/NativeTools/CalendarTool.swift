// OpenVision - CalendarTool.swift
import Foundation
import EventKit

/// Read and manage the user's real Apple Calendar through EventKit.
struct CalendarTool: NativeTool {
    let name = "calendar"
    let description = "Manage Apple Calendar on the iPhone. action 'today' lists today, 'upcoming' lists the next 7 days, 'add' creates an event, 'update' edits one matching event, and 'delete' removes one matching event. For update/delete use query to identify the event title."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "today, upcoming, add, update, or delete"],
            "query": ["type": "string", "description": "For update/delete: title or distinctive words from the target event"],
            "title": ["type": "string", "description": "Event title for add"],
            "new_title": ["type": "string", "description": "Optional replacement title for update"],
            "hour": ["type": "integer", "description": "For add/update at a clock time like 3pm: hour in 24-hour form (0-23)."],
            "minute": ["type": "integer", "description": "Minute 0-59 (with hour). Default 0."],
            "day_offset": ["type": "integer", "description": "With hour: 0=today, 1=tomorrow, 2=in two days. Default 0."],
            "minutes_from_now": ["type": "integer", "description": "For add/update: time this many minutes from now. Use only for relative requests."],
            "start_iso8601": ["type": "string", "description": "Absolute start time in ISO 8601. Last resort only."],
            "duration_minutes": ["type": "integer", "description": "Length in minutes. For add defaults to 30; for update changes duration if supplied."]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "today").lowercased()
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .event)) ?? false
        }
        guard granted else {
            return "Preciso de acesso ao Calendário. Ative a permissão nos Ajustes do iPhone e tente novamente."
        }

        switch action {
        case "add":
            return try addEvent(args: args, store: store)
        case "update", "edit", "editar":
            return try updateEvent(args: args, store: store)
        case "delete", "remove", "cancel", "excluir", "apagar", "cancelar":
            return try deleteEvent(args: args, store: store)
        case "upcoming", "proximos", "próximos":
            return listEvents(store: store, upcoming: true)
        case "today", "hoje":
            return listEvents(store: store, upcoming: false)
        default:
            return "Ação de calendário desconhecida. Posso consultar hoje, próximos eventos, adicionar, editar ou excluir um compromisso."
        }
    }

    private func addEvent(args: [String: Any], store: EKEventStore) throws -> String {
        guard let title = clean(args["title"] as? String), !title.isEmpty else {
            return "Qual é o nome do compromisso?"
        }
        guard let start = NativeToolSupport.resolveDate(from: args) else {
            return "Quando o compromisso deve começar?"
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return "Não encontrei um calendário padrão com permissão de escrita no iPhone."
        }

        let minutes = max(1, NativeToolSupport.int(args["duration_minutes"]) ?? 30)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        event.calendar = calendar
        try store.save(event, span: .thisEvent)

        return "Adicionei \"\(title)\" no Calendário, \(NativeToolSupport.friendly(start))."
    }

    private func updateEvent(args: [String: Any], store: EKEventStore) throws -> String {
        guard let query = clean((args["query"] as? String) ?? (args["title"] as? String)), !query.isEmpty else {
            return "Qual compromisso você quer editar?"
        }
        let match = findUniqueEvent(query: query, store: store)
        guard let event = match.event else { return match.message }

        var changed = false
        if let newTitle = clean(args["new_title"] as? String), !newTitle.isEmpty {
            event.title = newTitle
            changed = true
        }

        let requestedStart = NativeToolSupport.resolveDate(from: args)
        let requestedDuration = NativeToolSupport.int(args["duration_minutes"])
        if let start = requestedStart {
            let oldDuration = max(event.endDate.timeIntervalSince(event.startDate), 60)
            let duration = requestedDuration.map { TimeInterval(max(1, $0) * 60) } ?? oldDuration
            event.startDate = start
            event.endDate = start.addingTimeInterval(duration)
            changed = true
        } else if let durationMinutes = requestedDuration {
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(max(1, durationMinutes) * 60))
            changed = true
        }

        guard changed else {
            return "Encontrei \"\(event.title ?? query)\", mas você não informou o que quer alterar."
        }

        try store.save(event, span: .thisEvent)
        return "Atualizei \"\(event.title ?? query)\" no Calendário para \(NativeToolSupport.friendly(event.startDate))."
    }

    private func deleteEvent(args: [String: Any], store: EKEventStore) throws -> String {
        guard let query = clean((args["query"] as? String) ?? (args["title"] as? String)), !query.isEmpty else {
            return "Qual compromisso você quer excluir?"
        }
        let match = findUniqueEvent(query: query, store: store)
        guard let event = match.event else { return match.message }

        let title = event.title ?? query
        let when = NativeToolSupport.friendly(event.startDate)
        try store.remove(event, span: .thisEvent)
        return "Excluí \"\(title)\" do Calendário, que estava marcado para \(when)."
    }

    private func listEvents(store: EKEventStore, upcoming: Bool) -> String {
        let now = Date()
        let cal = Calendar.current
        let start: Date
        let end: Date

        if upcoming {
            start = now
            end = cal.date(byAdding: .day, value: 7, to: now) ?? now
        } else {
            start = cal.startOfDay(for: now)
            end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? now
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else {
            return upcoming ? "Você não tem compromissos nos próximos sete dias." : "Você não tem compromissos no calendário hoje."
        }

        let list = events.prefix(8).map {
            "\($0.title ?? "Compromisso") — \(NativeToolSupport.friendly($0.startDate))"
        }.joined(separator: "; ")
        return "Encontrei \(events.count) compromisso\(events.count == 1 ? "" : "s"): \(list)."
    }

    private func findUniqueEvent(query: String, store: EKEventStore) -> (event: EKEvent?, message: String) {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        let end = cal.date(byAdding: .day, value: 60, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let target = normalized(query)
        let exact = events.filter { normalized($0.title ?? "") == target }
        if exact.count == 1 { return (exact[0], "") }
        if exact.count > 1 { return (nil, ambiguityMessage(exact, query: query)) }

        let partial = events.filter { normalized($0.title ?? "").contains(target) }
        if partial.count == 1 { return (partial[0], "") }
        if partial.count > 1 { return (nil, ambiguityMessage(partial, query: query)) }

        return (nil, "Não encontrei um compromisso futuro correspondente a \"\(query)\" nos próximos 60 dias.")
    }

    private func ambiguityMessage(_ events: [EKEvent], query: String) -> String {
        let examples = events.prefix(4).map {
            "\($0.title ?? query) — \(NativeToolSupport.friendly($0.startDate))"
        }.joined(separator: "; ")
        return "Encontrei mais de um compromisso correspondente a \"\(query)\": \(examples). Diga qual deles você quer alterar."
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clean(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
