// OpenVision - ReminderTool.swift
import Foundation
import EventKit

/// Create, list, edit, and remove items in Apple Reminders.
/// The legacy tool name stays `create_reminder` for compatibility with existing prompts/backends.
struct ReminderTool: NativeTool {
    let name = "create_reminder"
    let description = "Manage Apple Reminders on the iPhone. action defaults to 'create'. Use action 'list' to list incomplete reminders, 'update' to edit one matching reminder, and 'delete' to remove one. For update/delete use query to identify the reminder title."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "create, list, update, or delete. Default create."],
            "title": ["type": "string", "description": "Reminder title for create"],
            "query": ["type": "string", "description": "For update/delete: title or distinctive words from the target reminder"],
            "new_title": ["type": "string", "description": "Optional replacement title for update"],
            "hour": ["type": "integer", "description": "For a clock time like 6pm: hour in 24-hour form (0-23)."],
            "minute": ["type": "integer", "description": "Minute 0-59 (with hour). Default 0."],
            "day_offset": ["type": "integer", "description": "With hour: 0=today, 1=tomorrow, 2=in two days. Default 0."],
            "minutes_from_now": ["type": "integer", "description": "Due this many minutes from now. Use only for relative requests."],
            "due_iso8601": ["type": "string", "description": "Absolute due date/time in ISO 8601. Last resort only."]
        ]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "create").lowercased()
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        guard granted else {
            return "Preciso de acesso aos Lembretes. Ative a permissão nos Ajustes do iPhone e tente novamente."
        }

        switch action {
        case "list", "listar":
            return await listReminders(store: store)
        case "update", "edit", "editar":
            return try await updateReminder(args: args, store: store)
        case "delete", "remove", "excluir", "apagar":
            return try await deleteReminder(args: args, store: store)
        case "create", "add", "criar", "adicionar":
            return try createReminder(args: args, store: store)
        default:
            return "Ação de lembrete desconhecida. Posso criar, listar, editar ou excluir lembretes."
        }
    }

    private func createReminder(args: [String: Any], store: EKEventStore) throws -> String {
        guard let title = clean(args["title"] as? String), !title.isEmpty else {
            return "Do que você quer ser lembrado?"
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return "Não encontrei uma lista padrão de Lembretes com permissão de escrita."
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar

        var whenText = ""
        if let dueDate = NativeToolSupport.resolveDate(from: args) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            whenText = ", \(NativeToolSupport.friendly(dueDate))"
        }

        try store.save(reminder, commit: true)
        return "Criei o lembrete \"\(title)\"\(whenText)."
    }

    private func listReminders(store: EKEventStore) async -> String {
        let reminders = await fetchIncompleteReminders(store: store)
        guard !reminders.isEmpty else {
            return "Você não tem lembretes pendentes."
        }

        let sorted = reminders.sorted { lhs, rhs in
            let l = dueDate(of: lhs) ?? .distantFuture
            let r = dueDate(of: rhs) ?? .distantFuture
            return l < r
        }
        let list = sorted.prefix(10).map { reminder -> String in
            let title = reminder.title ?? "Lembrete"
            if let due = dueDate(of: reminder) {
                return "\(title) — \(NativeToolSupport.friendly(due))"
            }
            return title
        }.joined(separator: "; ")

        return "Você tem \(reminders.count) lembrete\(reminders.count == 1 ? "" : "s") pendente\(reminders.count == 1 ? "" : "s"): \(list)."
    }

    private func updateReminder(args: [String: Any], store: EKEventStore) async throws -> String {
        guard let query = clean((args["query"] as? String) ?? (args["title"] as? String)), !query.isEmpty else {
            return "Qual lembrete você quer editar?"
        }
        let reminders = await fetchIncompleteReminders(store: store)
        let match = findUniqueReminder(query: query, reminders: reminders)
        guard let reminder = match.reminder else { return match.message }

        var changed = false
        if let newTitle = clean(args["new_title"] as? String), !newTitle.isEmpty {
            reminder.title = newTitle
            changed = true
        }

        if let dueDate = NativeToolSupport.resolveDate(from: args) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
            if let alarms = reminder.alarms {
                for alarm in alarms { reminder.removeAlarm(alarm) }
            }
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            changed = true
        }

        guard changed else {
            return "Encontrei \"\(reminder.title ?? query)\", mas você não informou o que quer alterar."
        }

        try store.save(reminder, commit: true)
        if let due = dueDate(of: reminder) {
            return "Atualizei o lembrete \"\(reminder.title ?? query)\" para \(NativeToolSupport.friendly(due))."
        }
        return "Atualizei o lembrete \"\(reminder.title ?? query)\"."
    }

    private func deleteReminder(args: [String: Any], store: EKEventStore) async throws -> String {
        guard let query = clean((args["query"] as? String) ?? (args["title"] as? String)), !query.isEmpty else {
            return "Qual lembrete você quer excluir?"
        }
        let reminders = await fetchIncompleteReminders(store: store)
        let match = findUniqueReminder(query: query, reminders: reminders)
        guard let reminder = match.reminder else { return match.message }

        let title = reminder.title ?? query
        try store.remove(reminder, commit: true)
        return "Excluí o lembrete \"\(title)\"."
    }

    private func fetchIncompleteReminders(store: EKEventStore) async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func findUniqueReminder(query: String, reminders: [EKReminder]) -> (reminder: EKReminder?, message: String) {
        let target = normalized(query)
        let exact = reminders.filter { normalized($0.title ?? "") == target }
        if exact.count == 1 { return (exact[0], "") }
        if exact.count > 1 { return (nil, ambiguityMessage(exact, query: query)) }

        let partial = reminders.filter { normalized($0.title ?? "").contains(target) }
        if partial.count == 1 { return (partial[0], "") }
        if partial.count > 1 { return (nil, ambiguityMessage(partial, query: query)) }

        return (nil, "Não encontrei um lembrete pendente correspondente a \"\(query)\".")
    }

    private func ambiguityMessage(_ reminders: [EKReminder], query: String) -> String {
        let examples = reminders.prefix(4).map { reminder -> String in
            let title = reminder.title ?? query
            if let due = dueDate(of: reminder) {
                return "\(title) — \(NativeToolSupport.friendly(due))"
            }
            return title
        }.joined(separator: "; ")
        return "Encontrei mais de um lembrete correspondente a \"\(query)\": \(examples). Diga qual deles você quer alterar."
    }

    private func dueDate(of reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return Calendar.current.date(from: components)
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
