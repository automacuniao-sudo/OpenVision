// OpenVision - NativeToolSupport.swift
// Small shared helpers for the native tools (arg coercion, notification auth, date formatting).

import Foundation
import UserNotifications

/// User utterances that triggered recent model turns. Backends set the newest command before
/// invoking their model so native tools can sanity-check model-generated arguments against what
/// the user actually said. Keeping a short history also lets a referential follow-up such as
/// "pesquise no Google" recover the last meaningful topic instead of letting the model silently
/// switch from "último jogo" to "próximo jogo".
@MainActor
final class NativeToolContext {
    static let shared = NativeToolContext()
    private init() {}

    private struct Entry {
        let command: String
        let setAt: Date
    }

    private var entries: [Entry] = []
    private let maxEntries = 12
    private let maxAge: TimeInterval = 5 * 60

    func set(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        entries.removeAll { now.timeIntervalSince($0.setAt) >= maxAge }

        // Speech recognition can occasionally submit the exact same final command twice. Avoid
        // polluting the context stack with duplicates while still refreshing its timestamp.
        if entries.last?.command.caseInsensitiveCompare(trimmed) == .orderedSame {
            entries[entries.count - 1] = Entry(command: trimmed, setAt: now)
        } else {
            entries.append(Entry(command: trimmed, setAt: now))
        }

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// The newest utterance, if one was recorded recently.
    func recentCommand() -> String? {
        recentCommands().last
    }

    /// Recent utterances in chronological order. Native tools use this only to preserve explicit
    /// user intent across short follow-ups; stale conversation history is deliberately excluded.
    func recentCommands() -> [String] {
        let now = Date()
        entries.removeAll { now.timeIntervalSince($0.setAt) >= maxAge }
        return entries.map(\.command)
    }
}

enum NativeToolSupport {

    /// Minutes parsed from a clearly RELATIVE time phrase in the user's own words.
    /// Supports the pt-BR phrases used by JARVIS as well as the original English patterns.
    /// A bare duration ("30 minutos") intentionally does not match because it may mean event length.
    static func relativeMinutes(in command: String) -> Int? {
        let s = command
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()

        // Common natural one-off forms.
        let thirtyMinuteForms = ["em meia hora", "daqui a meia hora", "depois de meia hora", "in half an hour", "after half an hour"]
        if thirtyMinuteForms.contains(where: { s.contains($0) }) { return 30 }

        let oneHourForms = ["em uma hora", "em 1 hora", "daqui a uma hora", "daqui a 1 hora", "depois de uma hora", "in an hour", "after an hour"]
        if oneHourForms.contains(where: { s.contains($0) }) { return 60 }

        // Marker BEFORE the value: "em 15 minutos", "daqui a 2 horas", "after 20 min".
        let beforePattern = #"\b(?:em|daqui\s+a|depois\s+de|apos|in|after)\s+(\d+)\s*(minuto|minutos|min|mins|minute|minutes|hora|horas|hour|hours|hr|hrs|h)\b"#
        if let match = firstNumberAndUnit(pattern: beforePattern, in: s) {
            return match.isHours ? match.value * 60 : match.value
        }

        // Marker AFTER the value: "15 minutos a partir de agora", "20 min later".
        let afterPattern = #"\b(\d+)\s*(minuto|minutos|min|mins|minute|minutes|hora|horas|hour|hours|hr|hrs|h)\s+(?:a\s+partir\s+de\s+agora|a\s+contar\s+de\s+agora|from\s+now|later)\b"#
        if let match = firstNumberAndUnit(pattern: afterPattern, in: s) {
            return match.isHours ? match.value * 60 : match.value
        }

        return nil
    }

    private static func firstNumberAndUnit(pattern: String, in text: String) -> (value: Int, isHours: Bool)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Int(text[numberRange]) else { return nil }

        let unit = String(text[unitRange])
        let isHours = unit.hasPrefix("h") || unit.hasPrefix("hora") || unit.hasPrefix("hour")
        return (value, isHours)
    }

    /// Deterministic time guard: when the user's own words are RELATIVE, rewrite the model's
    /// time args to `minutes_from_now` parsed straight from the transcript. This prevents clock
    /// arithmetic mistakes and works for both Portuguese and English speech.
    static func applyRelativeTimeGuard(_ args: inout [String: Any], command: String?) -> Int? {
        guard let command, let rel = relativeMinutes(in: command) else { return nil }
        for key in ["hour", "minute", "day_offset", "due_iso8601", "start_iso8601"] {
            args.removeValue(forKey: key)
        }
        args["minutes_from_now"] = rel
        return rel
    }

    /// LLMs send numbers as Int, Double, or even String — coerce to Int.
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Ensure we can post local notifications (timers/alarms/pomodoro). Requests once if undetermined.
    static func ensureNotificationAuth() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// Human duration in pt-BR.
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) segundo\(seconds == 1 ? "" : "s")" }
        let m = seconds / 60, s = seconds % 60
        if m < 60 {
            return s == 0
                ? "\(m) minuto\(m == 1 ? "" : "s")"
                : "\(m) min \(s) s"
        }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h) hora\(h == 1 ? "" : "s")" : "\(h) h \(rm) min"
    }

    /// Parse an ISO-8601 timestamp the model provides for a due/start time.
    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Fall back to a lenient local parse ("2026-07-18 17:00").
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.date(from: s)
    }

    /// Resolve a target Date from tool args, preferring the most reliable source so the model
    /// never has to do clock arithmetic. Priority:
    ///   1. Absolute clock time — `hour` (0-23) + optional `minute` + optional `day_offset`.
    ///   2. `minutes_from_now` — a relative offset in minutes.
    ///   3. `due_iso8601` / `start_iso8601` — absolute ISO timestamp as last-resort fallback.
    static func resolveDate(from args: [String: Any]) -> Date? {
        let cal = Calendar.current
        let now = Date()

        // 1) Absolute clock time.
        if let hour = int(args["hour"]), (0...23).contains(hour) {
            let minute = min(max(int(args["minute"]) ?? 0, 0), 59)
            let dayOffset = int(args["day_offset"]) ?? 0
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard var date = cal.date(from: comps) else { return nil }
            if dayOffset != 0 {
                date = cal.date(byAdding: .day, value: dayOffset, to: date) ?? date
            } else if date <= now {
                // If no explicit day was given and today's time already passed, use tomorrow.
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }

        // 2) Relative minutes.
        if let rel = int(args["minutes_from_now"]), rel > 0 {
            return now.addingTimeInterval(TimeInterval(rel * 60))
        }

        // 3) ISO fallback.
        if let iso = (args["due_iso8601"] as? String) ?? (args["start_iso8601"] as? String),
           !iso.isEmpty {
            return parseISO(iso)
        }
        return nil
    }

    /// Friendly spoken date/time in Brazilian Portuguese.
    static func friendly(_ date: Date) -> String {
        let cal = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "pt_BR")
        time.dateFormat = "HH:mm"
        let t = time.string(from: date)

        if cal.isDateInToday(date) { return "hoje às \(t)" }
        if cal.isDateInTomorrow(date) { return "amanhã às \(t)" }

        let day = DateFormatter()
        day.locale = Locale(identifier: "pt_BR")
        day.dateFormat = "EEE, d 'de' MMM"
        return "\(day.string(from: date)) às \(t)"
    }
}
