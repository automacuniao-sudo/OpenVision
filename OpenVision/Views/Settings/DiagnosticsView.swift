// OpenVision - DiagnosticsView.swift

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @StateObject private var logger = DiagnosticLogger.shared
    @State private var copied = false

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
                ScrollView {
                    Text(logger.exportText.isEmpty ? "No diagnostic events yet." : logger.exportText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 300)
            } header: {
                Text("Logs")
            } footer: {
                Text("Logs may include speech transcripts and technical state, but never the Gemini API key.")
            }

            Section("Actions") {
                Button {
                    UIPasteboard.general.string = logger.exportText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Logs", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                ShareLink(item: logger.fileURL) {
                    Label("Share Log File", systemImage: "square.and.arrow.up")
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
}
