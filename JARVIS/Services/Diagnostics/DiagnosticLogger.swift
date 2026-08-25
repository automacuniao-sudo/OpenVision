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

    var exportText: String {
        entries.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        try? Data().write(to: fileURL, options: .atomic)
        log("App", "Diagnostics cleared")
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
