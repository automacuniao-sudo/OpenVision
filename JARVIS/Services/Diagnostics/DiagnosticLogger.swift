// JARVIS - DiagnosticLogger.swift
// Persistent in-app diagnostics for Windows/GitHub Actions/Sideloadly development.

import Foundation
import Combine

@MainActor
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var entries: [String] = []
    let fileURL: URL

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let maxEntries = 1000
    private let sessionMarker = "[App] Diagnostics initialized —"

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("jarvis-diagnostics.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), !existing.isEmpty {
            entries = Array(existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(maxEntries))
        }

        log("App", "Diagnostics initialized — JARVIS \(Config.appVersion) (\(Config.buildNumber))")
    }

    func log(_ category: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(line + "\n")
        print("[Diagnostics] \(line)")
    }

    /// Entire retained history. Keep this for deep investigations and the raw file export.
    var exportText: String {
        entries.joined(separator: "\n")
    }

    /// Only events from the latest app launch. This is the best default payload for most tests:
    /// it excludes old builds/sessions while retaining wake word, STT, backend, audio and tool state.
    var currentSessionText: String {
        packaged(scope: "current app session", lines: currentSessionEntries)
    }

    /// Compact context around the most recent failure in the current app session.
    /// If no explicit failure marker exists yet, return the last 120 session lines instead.
    var latestFailureContextText: String {
        let session = currentSessionEntries
        guard !session.isEmpty else {
            return packaged(scope: "latest failure context", lines: [])
        }

        let markers = [
            "error", "failed", "failure", "socket is not connected", "server api error",
            "provider error", "quota", "429", "fatal", "crash"
        ]

        guard let failureIndex = session.lastIndex(where: { line in
            let normalized = line.lowercased()
            return markers.contains(where: normalized.contains)
        }) else {
            return packaged(scope: "recent context (no explicit failure found)", lines: Array(session.suffix(120)))
        }

        let start = max(0, failureIndex - 80)
        let end = min(session.count - 1, failureIndex + 25)
        return packaged(scope: "latest failure context", lines: Array(session[start...end]))
    }

    func recentText(limit: Int = 200) -> String {
        let safeLimit = max(1, limit)
        return packaged(scope: "last \(safeLimit) retained lines", lines: Array(entries.suffix(safeLimit)))
    }

    func clear() {
        entries.removeAll()
        try? Data().write(to: fileURL, options: .atomic)
        log("App", "Diagnostics cleared")
    }

    private var currentSessionEntries: [String] {
        guard let start = entries.lastIndex(where: { $0.contains(sessionMarker) }) else {
            return entries
        }
        return Array(entries[start...])
    }

    private func packaged(scope: String, lines: [String]) -> String {
        let header = [
            "JARVIS Diagnostics",
            "Build: \(Config.appVersion) (\(Config.buildNumber))",
            "Scope: \(scope)",
            "----------------------------------------"
        ]
        return (header + lines).joined(separator: "\n")
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("[Diagnostics] File write failed: \(error.localizedDescription)")
        }
    }
}
