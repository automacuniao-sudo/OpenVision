// JARVIS - CurrentDateTimeTool.swift
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
