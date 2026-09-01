// OpenVision - DiagnosticsView.swift

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @StateObject private var logger = DiagnosticLogger.shared
    @State private var copiedAction: String?
    @State private var showFullHistory = false

    var body: some View {
        List {
            Section("Build") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(Config.appVersion) (\(Config.buildNumber))")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Show Full History", isOn: $showFullHistory)

                ScrollView {
                    Text(displayedLog.isEmpty ? "No diagnostic events yet." : displayedLog)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 300)
            } header: {
                Text("Logs")
            } footer: {
                Text("By default, only the current app session is shown. Logs may include speech transcripts and technical state, but never the Gemini API key.")
            }

            Section("Quick Copy") {
                Button {
                    copy(logger.latestFailureContextText, action: "failure")
                } label: {
                    Label(
                        copiedAction == "failure" ? "Last Failure Copied" : "Copy Last Failure",
                        systemImage: copiedAction == "failure" ? "checkmark" : "exclamationmark.triangle"
                    )
                }

                Button {
                    copy(logger.currentSessionText, action: "session")
                } label: {
                    Label(
                        copiedAction == "session" ? "Session Copied" : "Copy Current Session",
                        systemImage: copiedAction == "session" ? "checkmark" : "doc.on.doc"
                    )
                }
            }

            Section("Advanced") {
                Button {
                    copy(logger.exportText, action: "full")
                } label: {
                    Label(
                        copiedAction == "full" ? "Full Log Copied" : "Copy Full Log",
                        systemImage: copiedAction == "full" ? "checkmark" : "doc.on.doc.fill"
                    )
                }

                ShareLink(item: logger.fileURL) {
                    Label("Share Full Log File", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    logger.clear()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayedLog: String {
        showFullHistory ? logger.exportText : logger.currentSessionText
    }

    private func copy(_ text: String, action: String) {
        UIPasteboard.general.string = text
        copiedAction = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedAction == action {
                copiedAction = nil
            }
        }
    }
}
